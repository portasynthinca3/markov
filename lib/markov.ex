defmodule Markov do
  @moduledoc """
  Public API.

  Example workflow:

      # the model is to be stored under /base/directory/model_name
      # the model will be created using specified options if not found
      {:ok, model} = Markov.load("/base/directory", "model_name", sanitize_tokens: true, store_history: [:train])

      # train using four strings
      model
        |> Markov.train("hello, world!")
        |> Markov.train("example string number two")
        |> Markov.train("hello, Elixir!")
        |> Markov.train("fourth string")

      # generate text
      model |> Markov.generate_text |> IO.inspect

      # unload model from RAM
      model |> Markov.unload

      # this will raise because the model is unloaded
      # model |> Markov.generate_text |> IO.inspect
      # model |> Markov.train("hello, world!")

      # load the model again
      {:ok, model} = Markov.load("/base/directory", "model_name")

      # enable probability shifting and generate text
      model
        |> Markov.configure(shift_probabilities: true)
        |> Markov.generate_text |> IO.inspect

      # print uninteresting stats
      model |> Markov.stats |> IO.inspect
      model |> Markov.training_data |> IO.inspect

      # this will also write our new just-set option
      model |> Markov.unload
  """

  @opaque model_reference() :: pid()

  @typedoc """
  Model options that could be set during creation in a call to `load/3`
  or with `configure/2`, all `false` (or `[]` for `store_history`) by default:
    - `sanitize_tokens`: ignores letter case and punctuation when switching states,
    but still keeps the output as-is. Can't be disabled once enabled
    - `store_history`: determines what data to put in the operation log:
      - `:train`: training history
      - `:gen`: generation history
    - `shift_probabilities`: gives less popular generation paths more chance to
    get used, which makes the output more original but may produce nonsense
    - `partition_size`: approximate number of link entries in one partition
    (default: 10k)
    - `partition_timeout`: partition is unloaded from RAM after that many
    milliseconds of inactivity (default: 60k)
  """
  @type model_option() ::
    {:sanitize_tokens, boolean()} |
    {:store_history, [:train | :gen]} |
    {:shift_probabilities, boolean()} |
    {:partition_size, integer()} |
    {:partition_timeout, integer()}

  @spec default_opts() :: [model_option()]
  defp default_opts do
    [
      sanitize_tokens: false,
      store_history: [],
      shift_probabilities: false,
      partition_size: 10_000,
      partition_timeout: 60_000
    ]
  end

  @doc """
  Loads an existing model from `base_dir`/`name`. If none is found, a new model
  with the specified options at that path will be created and loaded, and if that
  fails, an error will be returned
  """
  @spec load(base_dir :: String.t(), name :: String.t(), options :: [model_option()]) ::
    {:ok, model_reference()} | {:error, term()}
  def load(base_dir, name, create_options \\ []) do
    # start process responsible for it
    Markov.ModelServer.start(
      name: name,
      path: Path.join(base_dir, name),
      create_opts: Keyword.merge(default_opts(), create_options)
    )
  end

  @doc """
  Unloads an already loaded model
  """
  @spec unload(model :: model_reference()) :: :ok
  def unload(model) do
    Markov.ModelServer.stop(model)
  end

  @doc """
  Reconfigures an already loaded model. See `model_option/0` for a thorough
  description of the options
  """
  @spec configure(model :: model_reference(), opts :: [model_option()]) :: :ok | {:error, term()}
  def configure(model, opts) do
    GenServer.call(model, {:configure, opts})
  end

  @doc """
  Gets the configuration of an already loaded model
  """
  @spec get_config(model :: model_reference()) :: {:ok, [model_option()]} | {:error, term()}
  def get_config(model) do
    GenServer.call(model, :get_config)
  end
end
