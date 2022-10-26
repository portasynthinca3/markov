defmodule Markov.ModelServer do
  use GenServer
  @moduledoc """
  GenServer in charge of one model

  Terminology:
    - The **master** is the file that persists a server's state (incl.
    repartitioning data, options, etc.)
    - A **partition** is a `dets` table that holds a preconfigured number of
    chain links.
    - **Repartitioning** occurs when, as a result of a training operation,
    the estimated average number of links in one partition has exceeded the
    preconfigured amount, so a new partition is created and data from the old
    ones is reshuffled between all new available partitions.

  Assuming this `Markov.load/3` call:
      Markov.load("/basepath", "model_name")
  This is the model structure on disk:
    - `basepath`
      - `model_name`
        - `master.etf.gz` - the master in gzipped Erlang's External Term Format
        - `operation_log.csetf` - the operation log in Concatenated Sized
  External Term Format. Each log entry is encoded in ETF, preceded with its
  16-bit size in bytes and appended to the log.
        - `part_0.dets` - partition number 0, a DETS table
        - `part_n.dets` - partition number n
  """

  require Logger

  defmodule State do
    defstruct [
      :name, :path,            # model name and path
      ring: %HashRing{},       # current ring during normal operation, old ring during a repartition
      new_ring: nil,           # inactive during normal operation, new ring during a repartition
      options: [],             # configured options
      repartition_status: %{}, # map of partition statuses during a repartition
      repartition_backlog: [], # training operations deferred until repartitioning is complete
      total_links: 0,          # total links across all partitions
      open_partitions: %{},    # map of currently loaded partitions to timeout process PIDs
      log_handle: nil,         # log file handle (append mode)
    ]
  end

  # Semi-public API

  @type start_options() :: [
    name: String.t(),
    path: String.t(),
    create_opts: [Markov.model_option()]
  ]

  @spec start(options :: start_options()) :: DynamicSupervisor.on_start_child()
  def start(options), do:
    DynamicSupervisor.start_child(Markov.ModelSup, %{
      id: options[:name],
      start: {Markov.ModelServer, :start_link, [options]},
      restart: :transient
    })

  @spec start_link(options :: start_options()) :: GenServer.on_start()
  def start_link(options) do
    proc_name = {:via, Registry, {Markov.ModelServers, options[:name]}}
    GenServer.start_link(__MODULE__, options, name: proc_name)
  end

  @spec init(options :: start_options()) :: {:ok, State.t()} | {:stop, term()}
  def init(options) do
    # for terminate/2 to work properly
    Process.flag(:trap_exit, true)

    try do
      # ignore "directory exists" errors but react to others
      mkdir_result = case File.mkdir(options[:path]) do
        :ok -> :ok
        {:error, :eexist} -> :ok
        {:error, err} -> err
      end
      case mkdir_result do
        :ok ->
          state = load_master!(options[:path])
          log(state, "loaded master")
          {:ok, log_handle} = File.open(Path.join(options[:path], "operation_log.csetf"), [:append])
          state = %State{state | log_handle: log_handle}
          write_log_entry(state, :start, nil)
          {:ok, state}

        err -> {:stop, err}
      end
    rescue
      _ ->
        # create a fresh model
        result = %State{
          name: options[:name],
          path: options[:path]
        } |> configure(options[:create_opts])

        case result do
          {:ok, state} ->
            state = open_partition!(state, 0)
            state = %State{state | ring: HashRing.add_node(state.ring, 0)}
            log(state, "created state")
            {:ok, log_handle} = File.open(Path.join(options[:path], "operation_log.csetf"), [:append])
            state = %State{state | log_handle: log_handle}
            write_log_entry(state, :start, nil)
            {:ok, state}

          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @spec terminate(_reason :: term(), state :: State.t()) :: term()
  def terminate(_reason, state) do
    save_master!(state)
    for part <- Map.keys(state.open_partitions) do
      close_partition!(state, part)
    end
    write_log_entry(state, :end, nil)
    File.close(state.log_handle)
  end

  @spec handle_call(request :: {:configure, [Markov.model_option()]},
    from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:configure, options}, _, state) do
    case configure(state, options) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @spec handle_call(request :: :get_config, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call(:get_config, _, state) do
    {:reply, {:ok, state.options}, state}
  end

  @spec handle_call(request :: :get_log_file, from :: term(), state :: State.t()) :: {:reply, String.t(), State.t()}
  def handle_call(:get_log_file, _, state) do
    {:reply, Path.join(state.path, "operation_log.csetf"), state}
  end

  @spec handle_call(request :: {:prepare_dump_info, integer}, from :: term(), state :: State.t()) :: {:reply, String.t(), State.t()}
  def handle_call({:prepare_dump_info, part}, _, state) do
    state = open_partition!(state, part)
    {:reply, {:ok, {:partition, state.name, part}}, state}
  end

  @spec handle_call(request :: {:train, [term()]}, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:train, tokens}, _, state) do
    # check if a repartition is in progress
    if map_size(state.repartition_status) > 0 do
      write_log_entry(state, :train_deferred, tokens)
      {:reply, {:ok, :deferred}, %State{state |
        repartition_backlog: [tokens | state.repartition_backlog]}}
    else
      state = do_train(state, tokens)
      {:reply, {:ok, :done}, state}
    end
  end

  @spec handle_info({:unload_part, integer()}, State.t()) :: {:noreply, State.t()}
  def handle_info({:unload_part, num}, state) do
    state = close_partition!(state, num)
    {:noreply, state}
  end

  @spec handle_info({:EXIT, pid(), :normal}, State.t()) :: {:noreply, State.t()}
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Internal functions

  @spec do_train(state :: State.t(), tokens :: [term()]) :: :ok
  defp do_train(state, tokens) do
    write_log_entry(state, :train, tokens)

    order = state.options[:order]
    tokens = Enum.map(0..(order-1), fn _ -> :start end) ++ tokens ++ [:end]
    Markov.ListUtil.overlapping_stride(tokens, order + 1) |> Enum.reduce(state, fn bit, state ->
      from = Enum.slice(bit, 0..-2)
      to = Enum.at(bit, -1)

      # sanitize tokens
      from = if state.options[:sanitize_tokens] do
        Enum.map(from, &Markov.TextUtil.sanitize_token/1)
      else from end

      partition = HashRing.key_to_node(state.ring, from)
      state = open_partition!(state, partition) # doesn't do anything if already open
      send(Map.get(state.open_partitions, partition), :defer) # signal usage
      links_from = :dets.lookup({:partition, state.name, partition}, from)
      links_from = case links_from do
        [] -> %{}
        [{^from, links}] -> links
      end

      new_weight = if links_from[to] == nil, do: 1, else: links_from[to] + 1
      links_from = Map.put(links_from, to, new_weight)
      :dets.insert({:partition, state.name, partition}, {from, links_from})
      state
    end)
  end

  @spec write_log_entry(state :: State.t(), type :: Markov.log_entry_type(), data:: term()) :: :ok | :ignored
  defp write_log_entry(state, type, data) do
    if type in state.options[:store_history] do
      log(state, "writing log entry #{type} #{inspect data}")
      data = :erlang.term_to_binary({:erlang.system_time(:millisecond), type, data})
      :ok = IO.binwrite(state.log_handle, <<byte_size(data)::16, data::binary>>)
      :ok
    else
      :ignored
    end
  end

  @spec log(state :: State.t(), string :: String.t()) :: term()
  defp log(state, string) do
    Logger.debug("model \"#{state.name}\" (#{self() |> inspect()}): #{string}")
  end

  @spec configure(old_state :: State.t(), opts :: [Markov.model_option()]) :: {:ok, State.t()} | {:error, term()}
  defp configure(old_state, opts) do
    log(old_state, "reconfiguring: #{inspect opts}")

    # special set-up and error detection for some options
    had_sanitation = old_state.options[:sanitize_tokens]
    previous_order = old_state.options[:order]

    statuses = for {key, value} <- opts do case key do
      :sanitize_tokens when had_sanitation != value and had_sanitation != nil ->
        {:error, :cant_change_sanitation}
      :order when previous_order != value and previous_order != nil ->
        {:error, :cant_change_order}

      _ -> :ok
    end end

    # report first error or merge options
    error = Enum.find(statuses, & &1 != :ok)
    if error !== nil, do: error, else:
      {:ok, %State{old_state | options: Keyword.merge(old_state.options, opts)}}
  end

  @spec save_master!(state :: State.t()) :: :ok
  defp save_master!(state) do
    data = state
      |> :erlang.term_to_binary
      |> :zlib.gzip
    Path.join(state.path, "master.etf.gz") |> File.write!(data)
    log(state, "saved master")
  end

  @spec load_master!(path :: String.t()) :: State.t()
  defp load_master!(path) do
    Path.join(path, "master.etf.gz")
      |> File.read!
      |> :zlib.gunzip
      |> :erlang.binary_to_term
      |> Map.replace(:open_partitions, %{})
      |> Map.replace(:log_handle, nil)
  end

  @spec open_partition!(state :: State.t(), num :: integer()) :: State.t()
  defp open_partition!(state, num) do
    if Map.has_key?(state.open_partitions, num) do
      state
    else
      file = Path.join(state.path, "part_#{num}.dets") |> :erlang.binary_to_list
      {:ok, _} = :dets.open_file({:partition, state.name, num}, file: file, ram_file: true)
      pid = Markov.PartTimeout.start_link(self(), state.options[:partition_timeout], num)
      log(state, "opened partition #{num}")
      %State{state | open_partitions: Map.put(state.open_partitions, num, pid)}
    end
  end

  @spec close_partition!(state :: State.t(), num :: integer()) :: State.t()
  defp close_partition!(state, num) do
    :ok = :dets.close({:partition, state.name, num})
    log(state, "closed partition #{num}")
    %State{state | open_partitions: Map.delete(state.open_partitions, num)}
  end
end
