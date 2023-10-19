defmodule Markov do
  @moduledoc """
  Public API

  Example workflow:

      # the model will be stored under the specified path
      # as it does not yet exist, it will be created using the specified options
      {:ok, model} = Markov.load("./model_path", sanitize_tokens: true, store_log: [:train])

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

      # the model is unloaded
      {:error, _} = Markov.generate_text(model)
      {:error, _} = Markov.train(model, "hello, world!")

      # load the model again
      {:ok, model} = Markov.load("./model_path")

      # enable probability shifting and generate text
      :ok = Markov.configure(model, shift_probabilities: true)
      {:ok, text} = Markov.generate_text(model)
      IO.puts(text)

      # print log
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
    {:order, integer()} |
    {:type, :normal | :hidden}

  @spec default_opts() :: [model_option()]
  defp default_opts do
    [
      store_log: [:start, :end, :train, :gen],
      shift_probabilities: false,
      sanitize_tokens: false,
      order: 2,
      type: :normal
    ]
  end

  @doc """
  Loads an existing model under path `path`. If none is found, a new model with
  the specified options will be created and loaded, and if that fails, an error
  will be returned.
  """
  @spec load(path :: String.t, options :: [model_option()]) :: {:ok, model_reference()} | {:error, term()}
  def load(path, create_options \\ []) do
    # start database
    result = DynamicSupervisor.start_child(Markov.ModelSup, %{
      id: path,
      start: {CubDB, :start_link, [path, [name: {:via, Registry, {Markov.ModelServers, path}}]]},
      restart: :transient
    })
    case result do
      {:ok, pid} ->
        # save create options
        CubDB.transaction(pid, fn tx ->
          opts = CubDB.Tx.get(tx, :options)
          tx = if opts, do: tx, else:
            CubDB.Tx.put(tx, :options, Keyword.merge(default_opts(), create_options))
          {:commit, tx, :ok}
        end)
        # refer to the server by name because it's supervised
        {:ok, {:via, Registry, {Markov.ModelServers, path}}}
      err -> err
    end
  end

  @doc """
  Unloads a loaded model.
  """
  @spec unload(model :: model_reference()) :: :ok
  def unload(model) do
    CubDB.stop(model)
  end

  @doc """
  Reconfigures a loaded model. The specified options are merged with the current
  ones. See type `model_option/0` for a thorough description of the options.
  """
  @spec configure(model :: model_reference(), new_opts :: [model_option()]) :: :ok | {:error, term()}
  def configure(model, new_opts) do
    CubDB.transaction(model, fn tx ->
      current_opts = CubDB.Tx.get(tx, :options)

      # enforce constant options
      cant_change = [:sanitize_tokens, :order]
      statuses = for option <- cant_change do
        if current_opts[option] != new_opts[option] and new_opts[option] do
          {:error, {:cant_change, option}}
        else
          :ok
        end
      end

      # report first error or apply options
      first_error = Enum.find(statuses, & &1 != :ok)
      case first_error do
        nil ->
          tx = CubDB.Tx.put(tx, :options, Keyword.merge(current_opts, new_opts))
          {:commit, tx, :ok}
        err ->
          {:cancel, err}
      end
    end)
  end

  @doc """
  Gets the configuration of a loaded model
  """
  @spec get_config(model :: model_reference()) :: [model_option()]
  def get_config(model) do
    CubDB.get(model, :options)
  end

  @doc """
  Trains `model` using text or a list of tokens.

      :ok = Markov.train(model, "Hello, world!")
      :ok = Markov.train(model, "each word in a string is a token")
      :ok = Markov.train(model, [
        :this, "is", 'a token', :list, "where",
        {:each_element, :is, {:taken, :as_is}},
        :and, :can_be, :erlang.make_ref(), "<-- any term"
      ])
      :ok = Markov.train(model, 'a charlist is a list, therefore every character is its own token')

  See `tag_query/0` for more info about `tags`.

  **Note:** do not use the tokens `:"$_start"` and `:"$_end"` as they are used
  internally
  """
  @spec train(model_reference(), String.t() | [term()], [term()]) :: :ok | {:error, term()}
  def train(model, text, tags \\ [:"$none"])
  def train(model, text, tags) when is_binary(text) do
    tokens = String.split(text)
    train(model, tokens, tags)
  end
  def train(model, tokens, tags) when is_list(tokens) do
    tags = if tags == [], do: [:"$none"], else: tags
    Markov.ModelActions.train(model, tokens, tags)
  end

  @typedoc """
  If data was tagged when training, you can use tag queries to alter the
  probabilities of certain generation paths

  ### Examples:

      # training
      iex> Markov.train(model, "hello earth", [
        {:action, :saying_hello}, # <- a tag can either be an atom or a tuple,
                                  #    however tuples can contain any data types
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

      # All generation paths have a score of 1 by default. Here we're telling
      # Markov to add 1 point to paths tagged with `:uppercase`;
      # "hello Elixir" now has a score of 2 and "hello earth" has a score of 1.
      # Thus, "hello Elixir" has a probability of 2/3, and "hello earth" has
      # that of 1/3
      iex> Markov.generate_text(model, %{uppercase: 1})
      {:ok, "hello Elixir"}
      iex> Markov.generate_text(model, %{uppercase: 1})
      {:ok, "hello Elixir"}
      iex> Markov.generate_text(model, %{uppercase: 1})
      {:ok, "hello earth"}

  **Note:** tags must be either atoms or tuples, however tuples can contain any
  data types.
  """
  @type tag_query() :: %{(atom() | tuple()) => non_neg_integer()}

  @doc """
  Generates a list of tokens

      iex> Markov.generate_tokens(model)
      {:ok, ["hello", "world"]}

  See type `tag_query/0` for more info about `tag_query`
  """
  @spec generate_tokens(model_reference(), tag_query()) :: {:ok, [term()]} | {:error, term()}
  def generate_tokens(model, tag_query \\ %{}) do
    Markov.ModelActions.generate(model, tag_query)
  end

  @doc """
  Generates a string. Will raise an exception if the model was trained on
  non-textual tokens at least once

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
end
