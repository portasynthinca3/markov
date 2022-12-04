defmodule Markov do
  @moduledoc """
  Public API

  Example workflow:

      # the model is to be stored under /base/directory/model_name
      # the model will be created using specified options if not found
      {:ok, model} = Markov.load("/base/directory", "model_name", sanitize_tokens: true, store_history: [:train])

      # train using four strings
      {:ok, _} = Markov.train(model, "hello, world!")
      {:ok, _} = Markov.train(model, "example string number two")
      {:ok, _} = Markov.train(model, "hello, Elixir!")
      {:ok, _} = Markov.train(model, "fourth string")

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
      model |> Markov.dump_partition(0) |> IO.inspect
      model |> Markov.read_log |> IO.inspect

      # this will also write our new just-set option
      Markov.unload(model)
  """

  @opaque model_reference() :: {:via, term(), term()}

  @type log_entry_type() ::
    :train        | :train_deferred |
    :repart_start | :repart_done |
    :start        | :end |
    :gen

  @typedoc """
  Model options that could be set during creation in a call to `load/3`
  or with `configure/2`:
    - `store_history`: determines what data to put in the operation log, all of them
    by default:
      - `:train`: training requests
      - `:train_deferred`: training requests that have been deferred to until after
      repartitioning is complete
      - `:gen`: generation results
      - `:repart_start` - repartition start
      - `:repart_done` - repartition done
      - `:start` - model is loaded
      - `:end` - model is unloaded
    - `shift_probabilities`: gives less popular generation paths more chance to
    get used, which makes the output more original but may produce nonsense; false
    by default
    - `partition_size`: approximate number of link entries in one partition, 10k
    by default
    - `partition_timeout`: partition is unloaded from RAM after that many
    milliseconds of inactivity, 10k by default
    - `sanitize_tokens`: ignores letter case and punctuation when switching states,
    but still keeps the output as-is; false by default, can't be changed once the
    model is created
    - `order`: order of the chain, i.e. how many previous tokens the next one is
    based on; 2 by default, can never be changed once the model is created
  """
  @type model_option() ::
    {:store_history, [log_entry_type()]} |
    {:shift_probabilities, boolean()} |
    {:partition_size, integer()} |
    {:partition_timeout, integer()} |
    {:sanitize_tokens, boolean()} |
    {:order, integer()}

  @spec default_opts() :: [model_option()]
  defp default_opts do
    [
      store_history: [
        :train, :train_deferred,
        :repart_start, :repart_done,
        :start, :end,
        :gen
      ],
      shift_probabilities: false,
      partition_size: 10_000,
      partition_timeout: 10_000,
      sanitize_tokens: false,
      order: 2
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
    result = Markov.ModelServer.start(
      name: name,
      path: Path.join(base_dir, name),
      create_opts: Keyword.merge(default_opts(), create_options)
    )
    case result do
      # refer to the server by name because it's supervised and automatically
      # restarted
      {:ok, _pid} -> {:ok, {:via, Registry, {Markov.ModelServers, name}}}
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

      {:ok, _} = Markov.train(model, "Hello, world!")
      {:ok, _} = Markov.train(model, "this is a string that's broken down into tokens behind the scenes")
      {:ok, _} = Markov.train(model, [
        :this, "is", 'a token', :list, "where",
        {:each_element, :is, {:taken, :as_is}},
        :and, :can_be, :erlang.make_ref(), "<-- any term"
      ])

  Returns the status of the operation:
    - `:done` - training is complete
    - `:deferred` - a repartition is currently in progress, this request has
    been placed in the backlog to be fulfilled after repartitioning is complete

  See `generate_text/2` for more info about `specifiers`
  """
  @spec train(model_reference(), String.t() | [term()], [term()]) :: {:ok, :done | :deferred} | {:error, term()}
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
  If data was tagged when training, you can use tag queries to only select
  generation paths that match a set of criteria

    - `true` always matches
    - `{x, :or, y}` matches when either `x` or `y` matches
    - `{:not, x}` matches if x doesn't match, and vice versa
    - `{x, :score, y}` is only allowed at the top level; the total score counter
    (initially 0) is increased by `score` for every element `{query, score}` of
    `y` (a list) that matches; probabilities are then adjusted according to those
    scores.
    - any other term is treated as a tag (note the `:"$none"` tag - the default
    one)

  ### Examples:

      # training
      iex> Markov.train(model, "hello earth", [
        {:action, :saying_hello}, # <- terms of any type can function as tags
        {:subject_type, :planet},
        {:subject, "earth"},
        :lowercase
      ])
      {:ok, :done}
      iex> Markov.train(model, "Hello Elixir", [
        {:action, :saying_hello},
        {:subject_type, :programming_language},
        {:subject, "Elixir"},
        :uppercase
      ])
      {:ok, :done}


      # simple generation - both paths have equal probabilities
      iex> Markov.generate_text(model)
      {:ok, "hello earth"}
      iex> Markov.generate_text(model)
      {:ok, "hello Elixir"}

      # simple tag queries
      iex> Markov.generate_text(model, {:subject_type, :planet})
      {:ok, "hello earth"}
      iex> Markov.generate_text(model, :lowercase)
      {:ok, "hello earth"}
      iex> Markov.generate_text(model, {:subject_type, :programming_language})
      {:ok, "hello Elixir"}
      iex> Markov.generate_text(model, :uppercase)
      {:ok, "hello Elixir"}

      # both possible generation paths were tagged with this tag
      iex> Markov.generate_text(model, {:action, :saying_hello})
      {:ok, "hello earth"}
      iex> Markov.generate_text(model, {:action, :saying_hello})
      {:ok, "hello Elixir"}

      # both paths match, but "hello Elixir" has a score of 1 and "hello earth"
      # has a score of zero; thus, "hello Elixir" has a probability of 2/3, and
      # "hello earth" has that of 1/3
      iex> Markov.generate_text(model, {true, :score, [:uppercase]})
      {:ok, "hello Elixir"}
      iex> Markov.generate_text(model, {true, :score, [:uppercase]})
      {:ok, "hello earth"}
  """
  @type tag_query() ::
    true |
    {tag_query(), :or, tag_query()} |
    {tag_query(), :score, [{tag_query(), integer()}]} |
    {:not, tag_query()} |
    term()

  @doc """
  Predicts (generates) a list of tokens

      iex> Markov.generate_tokens(model)
      {:ok, ["hello", "world"]}

  See type `tag_query/0` for more info about `tags`
  """
  @spec generate_tokens(model_reference(), tag_query()) :: {:ok, [term()]} | {:error, term()}
  def generate_tokens(model, tag_query \\ true) do
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
  def generate_text(model, tag_query \\ true) do
    case generate_tokens(model, tag_query) do
      {:ok, text} -> {:ok, Enum.join(text, " ")}
      {:error, _} = err -> err
    end
  end

  @doc """
  Reads the log file and returns a list of entries in chronological order

      iex> Markov.read_log(model)
      {:ok,
       [
         {~U[2022-10-02 16:59:51.844Z], :start, nil},
         {~U[2022-10-02 16:59:56.705Z], :train, ["hello", "world"]}
       ]}
  """
  @spec read_log(model_reference()) :: {:ok, [{DateTime.t(), log_entry_type(), term()}]} | {:error, term()}
  def read_log(model) do
    path = GenServer.call(model, :get_log_file)
    {:ok, %File.Stat{size: size}} = File.stat(path)
    File.open(path, [:read], fn handle ->
      read_log_entries(handle, size, 0) |> :lists.reverse
    end)
  end

  defp read_log_entries(handle, size, pos, acc \\ [])
  defp read_log_entries(_handle, size, pos, acc) when pos >= size, do: acc
  defp read_log_entries(handle, size, pos, acc) do
    <<entry_size::16>> = IO.binread(handle, 2)
    data = IO.binread(handle, entry_size)
    {unix_time, type, data} = :erlang.binary_to_term(data)
    {:ok, time} = DateTime.from_unix(unix_time, :millisecond)
    entry = {time, type, data}
    read_log_entries(handle, size, pos + 2 + entry_size, [entry | acc])
  end

  @doc "Reads an entire partition for debugging purposes"
  @spec dump_partition(model_reference(), integer()) :: [{[term()], term(), term(), integer()}]
  def dump_partition(model, part_no) do
    # the server opens the table for us
    {:ok, tid} = GenServer.call(model, {:prepare_dump_info, part_no})
    :ets.match(tid, :"$1") |> Enum.map(fn [x] -> x end)
  end

  @doc "Deletes model data. There's no going back :)"
  @spec nuke(model :: model_reference()) :: :ok
  def nuke(model) do
    GenServer.call(model, :nuke)
  end
end
