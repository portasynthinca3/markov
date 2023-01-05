defmodule Markov do
  @moduledoc """
  Public API

  Before using for the first time:

      $ mix amnesia.create -d Markov.Database --disk

  Example workflow:

      # The name can be an arbitrary term (not just a string).
      # It will be stored in a Mnesia DB and created from scratch using the specified
      # parameters if not found.
      # You should configure mnesia if you want to change its working dir, e.g.:
      # `config :mnesia, dir: "/var/data"`
      {:ok, model} = Markov.load("model_name", sanitize_tokens: true, store_log: [:train])

      # train using four strings
      :ok = Markov.train(model, "hello, world!")
      :ok = Markov.train(model, "example string number two")
      :ok = Markov.train(model, "hello, Elixir!")
      :ok = Markov.train(model, "fourth string")

      # generate text
      {:ok, text} = Markov.generate_text(model)
      IO.puts(text)

      # commit all changes and unload
      Markov.unload(model)

      # these will return errors because the model is unloaded
      # Markov.generate_text(model)
      # Markov.train(model, "hello, world!")

      # load the model again
      {:ok, model} = Markov.load("/base/directory", "model_name")

      # enable probability shifting and generate text
      :ok = Markov.configure(model, shift_probabilities: true)
      {:ok, text} = Markov.generate_text(model)
      IO.puts(text)

      # print uninteresting stats
      model |> Markov.dump_partition(0) |> IO.inspect
      model |> Markov.read_log |> IO.inspect

      # this will also write our new just-set option
      Markov.unload(model)
  """

  @opaque model_reference() :: {:via, term(), term()}

  @type log_entry_type() :: :start | :end | :train | :gen

  @typedoc """
  Model options that could be set during creation in a call to `load/3`
  or with `configure/2`:
    - `store_log`: determines what data to put in the operation log, all of them
    by default:
      - `:start` - model is loaded
      - `:end` - model is unloaded
      - `:train`: training requests
      - `:gen`: generation results
    - `shift_probabilities`: gives less popular generation paths more chance to
    get used, which makes the output more original but may produce nonsense; false
    by default
    - `sanitize_tokens`: ignores letter case and punctuation when switching states,
    but still keeps the output as-is; false by default, can't be changed once the
    model is created
    - `order`: order of the chain, i.e. how many previous tokens the next one is
    based on; 2 by default, can never be changed once the model is created
  """
  @type model_option() ::
    {:store_log, [log_entry_type()]} |
    {:shift_probabilities, boolean()} |
    {:sanitize_tokens, boolean()} |
    {:order, integer()}

  @spec default_opts() :: [model_option()]
  defp default_opts do
    [
      store_log: [:start, :end, :train, :gen],
      shift_probabilities: false,
      sanitize_tokens: false,
      order: 2
    ]
  end

  @doc """
  Loads an existing model named `name`. If none is found, a new model with the
  specified options will be created and loaded, and if that fails, an error will
  be returned.
  """
  @spec load(path :: String.t, options :: [model_option()]) :: {:ok, model_reference()} | {:error, term()}
  def load(path, create_options \\ []) do
    # start process responsible for it
    result = Markov.ModelServer.start(
      path: path,
      create_opts: Keyword.merge(default_opts(), create_options)
    )
    case result do
      # refer to the server by name because it's supervised and automatically
      # restarted
      {:ok, _pid} -> {:ok, {:via, Registry, {Markov.ModelServers, path}}}
      err -> err
    end
  end

  @doc """
  Unloads an already loaded model
  """
  @spec unload(model :: model_reference()) :: :ok
  def unload(model) do
    GenServer.stop(model)
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
  Trains `model` using text or a list of tokens.

      :ok = Markov.train(model, "Hello, world!")
      :ok = Markov.train(model, "this is a string that's broken down into tokens behind the scenes")
      :ok = Markov.train(model, [
        :this, "is", 'a token', :list, "where",
        {:each_element, :is, {:taken, :as_is}},
        :and, :can_be, :erlang.make_ref(), "<-- any term"
      ])

  See `generate_text/2` for more info about `tags`
  """
  @spec train(model_reference(), String.t() | [term()], [term()]) :: :ok | {:error, term()}
  def train(model, text, tags \\ [:"$none"])
  def train(model, text, tags) when is_binary(text) do
    tokens = String.split(text)
    train(model, tokens, tags)
  end
  def train(model, tokens, tags) when is_list(tokens) do
    tags = if tags == [], do: [:"$none"], else: tags
    GenServer.call(model, {:train, tokens, tags})
  end

  @typedoc """
  If data was tagged when training, you can use tag queries to alter the
  probabilities of certain generation paths

  ### Examples:

      # training
      iex> Markov.train(model, "hello earth", [
        {:action, :saying_hello}, # <- terms of any type can function as tags
        {:subject_type, :planet},
        {:subject, "earth"},
        :lowercase
      ])
      :ok
      iex> Markov.train(model, "Hello Elixir", [
        {:action, :saying_hello},
        {:subject_type, :programming_language},
        {:subject, "Elixir"},
        :uppercase
      ])
      :ok


      # simple generation - both paths have equal probabilities
      iex> Markov.generate_text(model)
      {:ok, "hello earth"}
      iex> Markov.generate_text(model)
      {:ok, "hello Elixir"}

      # "hello Elixir" has a score of 1 and "hello earth" has a score of zero;
      # thus, "hello Elixir" has a probability of 2/3, and "hello earth" has
      # that of 1/3
      iex> Markov.generate_text(model, %{uppercase: 1})
      {:ok, "hello Elixir"}
      iex> Markov.generate_text(model, %{uppercase: 1})
      {:ok, "hello earth"}
  """
  @type tag_query() :: %{term() => non_neg_integer()}

  @doc """
  Predicts (generates) a list of tokens

      iex> Markov.generate_tokens(model)
      {:ok, ["hello", "world"]}

  See type `tag_query/0` for more info about `tag_query`
  """
  @spec generate_tokens(model_reference(), tag_query()) :: {:ok, [term()]} | {:error, term()}
  def generate_tokens(model, tag_query \\ %{}) do
    GenServer.call(model, {:generate, tag_query})
  end

  @doc """
  Predicts (generates) a string. Will raise an exception if the model
  was trained on non-textual tokens at least once

      iex> Markov.generate_text(model)
      {:ok, "hello world"}

  See type `tag_query/0` for more info about `tags`
  """
  @spec generate_text(model_reference(), tag_query()) :: {:ok, binary()} | {:error, term()}
  def generate_text(model, tag_query \\ %{}) do
    case generate_tokens(model, tag_query) do
      {:ok, text} -> {:ok, Enum.join(text, " ")}
      {:error, _} = err -> err
    end
  end

  defmodule Operation do
    defstruct [:date_time, :type, :arg]
    @type t() :: %__MODULE__{date_time: DateTime.t(), type: Markov.log_entry_type(), arg: term()}
  end

  @doc """
  Reads the log file and returns a list of entries in chronological order

      iex> Markov.read_log(model)
      {:ok,
       [
         %Markov.Operation{date_time: ~U[2022-10-02 16:59:51.844Z], type: :start, arg: nil},
         %Markov.Operation{date_time: ~U[2022-10-02 16:59:56.705Z], type: :train, arg: ["hello", "world"]}
       ]}
  """
  defmodule Operation, do: defstruct [:date_time, :type, :arg]
  @spec read_log(model_reference()) :: [%Operation{}]
  def read_log(model) do
    {:via, Registry, {Markov.ModelServers, path}} = model
    {:ok, file} = :file.open(Path.join(path, "history.log"), [:read, :raw, :binary])
    do_read_log(file) |> :lists.reverse
  end

  defp do_read_log(file, acc \\ []) do
    case :file.read(file, 11) do
      {:ok, <<type::8, ts::64, len::16>>} ->
        {:ok, data} = :file.read(file, len)
        type = Map.get(Markov.ModelServer.rev_log_entry_map, type)
        date_time = DateTime.from_unix!(ts, :millisecond)
        data = :erlang.binary_to_term(data)
        acc = [%Operation{date_time: date_time, type: type, arg: data} | acc]
        do_read_log(file, acc)
      _ -> acc
    end
  end
end
