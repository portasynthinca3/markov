defmodule Markov.ModelServer do
  use GenServer
  @moduledoc """
  GenServer in charge of one model. Some terminology:
    - The **master** is the file that persists a server's state (incl.
    repartitioning data, options, etc.)
    - A **partition** is a `dets` table that holds a preconfigured number of
    chain links.
    - **Repartitioning** occurs when, as a result of a training operation,
    the estimated average number of links in one partition has exceeded the
    preconfigured amount, so a new partition is created and data from the old
    ones is reshuffled between all new available partitions.
  """

  require Logger

  defmodule State do
    defstruct [
      :name, :path,               # model name and path
      ring: %HashRing{},          # current ring during normal operation, old ring during a repartition
      new_ring: %HashRing{},      # inactive during normal operation, new ring during a repartition
      options: [],                # configured options
      repartition_status: %{},    # map of partition statuses during a repartition
      repartition_backlog: [],    # training operations deferred until repartitioning is complete
      total_links: 0,             # total links across all partitions
      total_partitions: 0,        # total partitions in use
      open_partitions: %MapSet{}  # set of currently loaded partitions
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
    DynamicSupervisor.start_child(Markov.ModelSup, {Markov.ModelServer, options})

  @spec stop(pid()) :: :ok
  def stop(pid), do:
    DynamicSupervisor.terminate_child(Markov.ModelSup, pid)

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
            log(state, "created state")
            {:ok, state}

          {:error, reason} -> {:stop, reason}
        end
    end
  end

  @spec terminate(_reason :: term(), state :: State.t()) :: term()
  def terminate(_reason, state) do
    save_master!(state)
    for part <- MapSet.to_list(state.open_partitions) do
      close_partition!(state, part)
    end
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

  # Internal functions

  @spec log(state :: State.t(), string :: String.t()) :: term()
  defp log(state, string) do
    Logger.debug("model \"#{state.name}\" (#{self() |> inspect()}): #{string}")
  end

  @spec configure(old_state :: State.t(), opts :: [Markov.model_option()]) :: {:ok, State.t()} | {:error, term()}
  defp configure(old_state, opts) do
    log(old_state, "reconfiguring: #{inspect opts}")

    # special set-up and error detection for some options
    had_sanitation = old_state.options[:sanitize_tokens]

    statuses = for {key, value} <- opts do case key do
      :sanitize_tokens when not value and had_sanitation ->
        {:error, :cant_disable_sanitation}

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
      |> Map.replace(:open_partitions, %MapSet{})
  end

  @spec open_partition!(state :: State.t(), num :: integer()) :: {:partition, String.t(), integer()}
  defp open_partition!(state, num) do
    file = Path.join(state.path, "part_#{num}.dets")
    {:ok, name} = :dets.open_file({:partition, state.name, num}, file: file, ram_file: true)
    log(state, "opened partition #{num}")
    name
  end

  @spec open_partition!(state :: State.t(), num :: integer()) :: :ok
  defp close_partition!(state, num) do
    :ok = :dets.close({:partition, state.name, num})
    log(state, "closed partition #{num}")
    :ok
  end
end
