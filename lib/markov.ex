defmodule Markov do
  @moduledoc """
  Public API.

  Example workflow:

      # the model is to be stored under /base/directory/model_name
      # the model will be created using specified options if not found
      {:ok, model} = Markov.load("/base/directory", "model_name", sanitize_tokens: true, store_history: [:train])

      # train using four strings
      :ok = Markov.train(model, "hello, world!")
      :ok = Markov.train(model, "example string number two")
      :ok = Markov.train(model, "hello, Elixir!")
      :ok = Markov.train(model, "fourth string")

      # generate text
      {:ok, text} = Markov.generate_text(model)
      IO.inspect(text)

      # unload model from RAM
      Markov.unload(model)

      # these will return errors because the model is unloaded
      # Markov.generate_text(model)
      # Markov.train(model, "hello, world!")

      # load the model again
      {:ok, model} = Markov.load("/base/directory", "model_name")

      # enable probability shifting and generate text
      :ok = Markov.configure(model, shift_probabilities: true)
      {:ok, text} = Markov.generate_text(model)
      IO.inspect(text)

      # print uninteresting stats
      model |> Markov.stats |> IO.inspect
      model |> Markov.training_data |> IO.inspect

      # this will also write our new just-set option
      Markov.unload(model)
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

  @doc """
  Trains `chain` using text or a list of tokens.

      :ok = Markov.train(model, "Hello, world!")
      :ok = Markov.train(model, "this is a string that's broken down into tokens behind the scenes")
      :ok = Markov.train(model, [
        :this, "is", 'a token', :list, "where",
        {:each_element, :is, {:taken, :as_is},
         :and, :can_be, :erlang.make_ref(), "<-- any term"}
      ])
  """
  @spec train(model_reference(), String.t() | [term()]) :: :ok | {:error, term()}
  def train(model, text) when is_binary(text) do
    tokens = String.split(text)
    train(model, tokens)
  end
  def train(model, tokens) when is_list(tokens) do
    tokens = [:start, :start] ++ tokens ++ [:end]
    GenServer.call(model, {:train, tokens})
  end
end
