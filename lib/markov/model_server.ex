defmodule Markov.ModelServer do
  use GenServer
  @moduledoc """
  GenServer in charge of one model
  """

  @main_table_options [keys: 3, compress: true, part_initial: 512, part_size: 10_000, part_timeout: 250, slot_size: 1024]
  @log_entry_mapping %{start: 1, end: 2, train: 3, gen: 4}
  def log_entry_mapping, do: @log_entry_mapping
  def rev_log_entry_map, do: @log_entry_mapping |> Enum.map(fn {k, v} -> {v, k} end) |> Enum.into(%{})

  require Logger
  alias Markov.ModelActions

  defmodule State do
    defstruct [:path, options: [], main_table: nil, history_file: nil, aboba: 1]
    @type t :: %Markov.ModelServer.State{
      path: String.t,
      options: [Markov.model_option],
      main_table: Sidx.Table.t,
      history_file: :file.io_device,
      aboba: integer()
    }
  end

  # Semi-public API

  @type start_options() :: [
    path: String.t(),
    create_opts: [Markov.model_option]
  ]

  @spec start(options :: start_options()) :: DynamicSupervisor.on_start_child()
  def start(options), do:
    DynamicSupervisor.start_child(Markov.ModelSup, %{
      id: options[:path],
      start: {Markov.ModelServer, :start_link, [options]},
      restart: :transient
    })

  @spec start_link(options :: start_options()) :: GenServer.on_start()
  def start_link(options) do
    proc_name = {:via, Registry, {Markov.ModelServers, options[:path]}}
    GenServer.start_link(__MODULE__, options, name: proc_name)
  end

  @spec init(options :: start_options()) :: {:ok, State.t()} | {:stop, term()}
  def init(options) do
    # for terminate/2 to work properly
    Process.flag(:trap_exit, true)

    # read state
    path = options[:path]
    File.mkdir_p(path)
    state = case File.read(Path.join(path, "state.etf")) do
      {:ok, data} -> :erlang.binary_to_term(data)
      {:error, :enoent} -> %State{options: options[:create_opts]}
      {:error, err} -> raise err
    end

    # open tables
    main = Sidx.open!(Path.join(path, "main"), @main_table_options)
    {:ok, history} = :file.open(Path.join(path, "history.log"), [:append, :binary, :raw])

    state = %State{state | main_table: main, history_file: history, path: path}
    log(state, "loaded state and tables")
    write_log_entry(state, :start, nil)
    {:ok, state}
  end

  @spec terminate(reason :: term(), state :: State.t()) :: term()
  def terminate(_reason, state) do
    write_log_entry(state, :end, nil)

    # dump everything
    state_bin = :erlang.term_to_binary(state)
    File.write!(Path.join(state.path, "state.etf"), state_bin)
    :file.close(state.history_file)
    Sidx.close!(state.main_table)
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

  @spec handle_call(request :: {:train, [term()], [term()]}, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:train, tokens, tags}, _, state) do
    write_log_entry(state, :train, tokens)
    {:reply, ModelActions.train(state, tokens, tags), state}
  end

  @spec handle_call(request :: {:generate, Markov.tag_query()}, from :: term(), state :: State.t()) :: {:reply, term(), State.t()}
  def handle_call({:generate, tag_query}, _, state) do
    {result, state} = ModelActions.generate(state, tag_query)
    write_log_entry(state, :gen, result)
    {:reply, result, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == self() ->
        {:stop, reason, state}
      reason == :normal or reason == :shutdown ->
        {:noreply, state}
      true ->
        {:stop, reason, state}
    end
  end

  # Internal functions

  @spec write_log_entry(state :: State.t(), type :: Markov.log_entry_type(), data :: term()) :: :ok | :ignored | {:error, term()}
  defp write_log_entry(state, type, data) do
    if type in state.options[:store_log] do
      type = Map.get(@log_entry_mapping, type)
      ts = :erlang.system_time(:millisecond)
      data = :erlang.term_to_binary(data)
      :file.write(state.history_file, <<type::8, ts::64, byte_size(data)::16, data::binary>>)
    else :ignored end
  end

  @spec log(state :: State.t(), string :: String.t()) :: term()
  defp log(state, string), do:
    Logger.debug("model \"#{state.path}\" (#{inspect(self())}): #{string}")

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
end
