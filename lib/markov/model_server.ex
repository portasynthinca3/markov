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
  alias Markov.ModelActions

  defmodule State do
    defstruct [
      :name, :path,            # model name and path
      ring: %HashRing{},       # current ring during normal operation, old ring during a repartition
      new_ring: nil,           # inactive during normal operation, new ring during a repartition
      options: [],             # configured options
      repartition_status: nil, # map of partition statuses during a repartition
      repartition_backlog: [], # training operations deferred until repartitioning is complete
      total_links: 0,          # total links across all partitions
      open_partitions: %{},    # map of currently loaded partitions to ets talbes and timeout process PIDs
      log_handle: nil,         # log file handle (append mode)
    ]
    @type t :: %__MODULE__{
      name: String.t(), path: String.t(),
      ring: HashRing.t(),
      new_ring: HashRing.t() | nil,
      options: [Markov.model_option()],
      repartition_status: %{term() => non_neg_integer()} | nil,
      repartition_backlog: [{[term()], [term()]}],
      total_links: non_neg_integer(),
      open_partitions: %{non_neg_integer() => {:ets.tid(), pid()}},
      log_handle: File.io_device()
    }
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

  @spec handle_call(request :: {:prepare_dump_info, integer}, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:prepare_dump_info, part}, _, state) do
    state = open_partition!(state, part)
    {tid, _} = Map.get(state.open_partitions, part)
    {:reply, {:ok, tid}, state}
  end

  @spec handle_call(request :: {:train, [term()], [term()]}, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:train, tokens, tags}, _, state) do
    # check if a repartition is in progress
    if state.repartition_status != nil do
      write_log_entry(state, :train_deferred, tokens)
      {:reply, {:ok, :deferred}, %State{state |
        repartition_backlog: [{tokens, tags} | state.repartition_backlog]}}
    else
      state = ModelActions.train(state, tokens, tags)
      write_log_entry(state, :train, tokens)

      current_parts = length(HashRing.nodes(state.ring))
      max_links = current_parts * state.options[:partition_size]

      if state.total_links > max_links do
        # begin repartitioning
        state = %{state |
          new_ring: HashRing.add_node(state.ring, current_parts),
          repartition_status: %{}
        }
        write_log_entry(state, :repart_start, current_parts)
        {:reply, {:ok, :done}, state, {:continue, {:repart, 0}}}
      else
        {:reply, {:ok, :done}, state}
      end
    end
  end

  @spec handle_call(request :: {:generate, Markov.tag_query()}, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:generate, tag_query}, _, state) do
    {result, state} = ModelActions.generate(state, tag_query)
    write_log_entry(state, :gen, result)
    {:reply, result, state}
  end

  @spec handle_call(request :: :nuke, from :: term(), state :: State.t()) :: :ok
  def handle_call(:nuke, _, state) do
    state.ring |> HashRing.nodes() |> Enum.map(fn part ->
      {table, _} = Map.get(state.open_partitions, part)
      :dets.close(table)
      path = Path.join(state.path, "part_#{part}.dets")
      File.rm(path)
    end)

    Path.join(state.path, "operation_log.csetf") |> File.rm()
    state = %State{
      name: state.name,
      path: state.path,
      options: state.options,
      log_handle: state.log_handle,
      ring: HashRing.add_node(%HashRing{}, 0)
    } |> open_partition!(0)

    {:reply, :ok, state}
  end

  @spec handle_info({:unload_part, integer()}, State.t()) :: {:noreply, State.t()}
  def handle_info({:unload_part, num}, state) do
    state = close_partition!(state, num)
    {:noreply, state}
  end

  @spec handle_info({:EXIT, pid(), :normal}, State.t()) :: {:noreply, State.t()}
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Internal functions

  @spec handle_continue({:repart, non_neg_integer() | :cleanup}, State.t())
    :: {:noreply, State.t(), {:continue, {:repart, non_neg_integer()}}}
     | {:noreply, State.t()}
  def handle_continue({:repart, part}, state) when is_integer(part) do
    state = open_partition!(state, part)
    {table, _} = Map.get(state.open_partitions, part)

    state = traverse_partition(state, part, :ets.first(table))

    current_parts = length(HashRing.nodes(state.ring))
    next_part = part + 1
    if next_part >= current_parts do
      {:noreply, state, {:continue, {:repart, :cleanup}}}
    else
      {:noreply, state, {:continue, {:repart, next_part}}}
    end
  end

  def handle_continue({:repart, :cleanup}, state) do
    log(state, "repart: cleaning up")

    # remove old links
    _ = Enum.reduce(state.repartition_status, state, fn {key, _}, state ->
      old_part = HashRing.key_to_node(state.ring, key)
      state = open_partition!(state, old_part)
      {table, timeout_pid} = Map.get(state.open_partitions, old_part)
      send(timeout_pid, :defer)

      :ets.delete(table, key)
      log(state, "repart: deleted #{inspect key} from #{old_part}")

      state
    end)

    # update state
    moved_links = map_size(state.repartition_status)
    state = %{state |
      new_ring: nil,
      repartition_status: nil,
      ring: state.new_ring,
    }

    # work through the backlog
    state = Enum.reduce(state.repartition_backlog, state, fn {tokens, tags}, state ->
      log(state, "repart: training #{inspect tokens} #{inspect tags}")
      ModelActions.train(state, tokens, tags)
    end)

    write_log_entry(state, :repart_done, %{
      moved_links: moved_links,
      moved_links_percent: moved_links * 100.0 / state.total_links
    })
    {:noreply, %{state | repartition_backlog: []}}
  end

  @spec traverse_partition(State.t(), non_neg_integer(), [term()] | :"$end_of_table") :: State.t()
  defp traverse_partition(state, _part, :"$end_of_table"), do: state
  defp traverse_partition(state, part, key) do
    state = open_partition!(state, part)
    {table, timeout_pid} = Map.get(state.open_partitions, part)
    send(timeout_pid, :defer)

    new_part = HashRing.key_to_node(state.new_ring, key)
    state = if new_part != part do
      state = open_partition!(state, new_part)
      {new_table, new_to_pid} = Map.get(state.open_partitions, new_part)
      send(new_to_pid, :defer)

      objects = :ets.lookup(table, key)
      for object <- objects, do: :ets.insert(new_table, object)

      log(state, "repart: copied #{inspect key} #{part} -> #{new_part}")

      %{state | repartition_status: Map.put(state.repartition_status, key, new_part)}
    else state end

    next_key = :ets.next(table, key)
    traverse_partition(state, part, next_key)
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
  def open_partition!(state, num) do
    if Map.has_key?(state.open_partitions, num) do
      state
    else
      file = Path.join(state.path, "part_#{num}.dets") |> :erlang.binary_to_list
      {:ok, _} = :dets.open_file({:partition, state.name, num}, file: file, type: :bag)
      tid = :ets.new(:partition, [:bag, :public])
      ^tid = :dets.to_ets({:partition, state.name, num}, tid)
      pid = Markov.PartTimeout.start_link(self(), state.options[:partition_timeout], num)
      log(state, "opened partition #{num}")
      %State{state | open_partitions: Map.put(state.open_partitions, num, {tid, pid})}
    end
  end

  @spec close_partition!(state :: State.t(), num :: integer()) :: State.t()
  defp close_partition!(state, num) do
    {tid, _} = Map.get(state.open_partitions, num)
    :ets.to_dets(tid, {:partition, state.name, num})
    :ok = :dets.close({:partition, state.name, num})
    :ets.delete(tid)
    log(state, "closed partition #{num}")
    %State{state | open_partitions: Map.delete(state.open_partitions, num)}
  end
end
