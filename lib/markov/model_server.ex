defmodule Markov.ModelServer do
  use GenServer
  @moduledoc """
  GenServer in charge of one model
  """

  use Amnesia
  require Logger
  alias Markov.ModelActions
  alias Markov.Database.{Master, Operation}

  defmodule State do
    defstruct [:name, options: []]
    @type t :: %__MODULE__{name: term(), options: [Markov.model_option()]}
  end

  # Semi-public API

  @type start_options() :: [
    name: String.t(),
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

    state = Amnesia.transaction do
      case Master.read(options[:name]) do
        %Master{} = master -> master.state
        nil ->
          state = %State{name: options[:name], options: options[:create_opts]}
          log(state, "created state")
          Master.write(%Master{model: state.name, state: state})
          state
      end
    end

    log(state, "loaded master")
    write_log_entry(state, :start, nil)
    {:ok, state}
  end

  @spec terminate(reason :: term(), state :: State.t()) :: term()
  def terminate(_reason, state) do
    save_master!(state)
    write_log_entry(state, :end, nil)
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

  @spec write_log_entry(state :: State.t(), type :: Markov.log_entry_type(), data :: term()) :: :ok | :ignored
  defp write_log_entry(state, type, data) do
    if type in state.options[:store_log] do
      log(state, "log: #{type} #{inspect data}")
      %Operation{
        model: state.name,
        type: type,
        ts: :erlang.system_time(:millisecond),
        argument: data
      } |> Operation.write!
    else :ignored end
  end

  @spec log(state :: State.t(), string :: String.t()) :: term()
  defp log(state, string), do:
    Logger.debug("model #{inspect(state.name)} (#{inspect(self())}): #{string}")

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
    %Master{
      model: state.name,
      state: state
    } |> Master.write!
  end
end
