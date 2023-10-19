defmodule Markov.ModelActions do
  @moduledoc """
  Performs training, generation and probability shifting. Supposed to only ever
  be directly invoked by the `Markov` API frontend.
  """

  import Nx.Defn
  @nx_batch_size 1024

  @spec process_scores(rows :: [{to :: term(), tag :: term(), freq :: non_neg_integer()}], tag_scores: Markov.tag_query)
    :: %{to :: term() => score :: non_neg_integer()}
  def process_scores(rows, tag_scores) do
    # get a set of tags
    tag_set = Map.keys(tag_scores) |> MapSet.new
    rows
      # create a map of target tokens to rows
      # example:
      #   [{"hello", :tag, 1}, {"world", :tag_two, 1}] ->
      #   %{"hello" => [{"hello", :tag, 1}], "world" => [{"world", :tag_two, 1}]}
      |> Enum.group_by(fn {to, _, _} -> to end)
      # convert rows in map values to tag sets
      # example:
      #   %{"hello" => [{"hello", :tag, 1}], "world" => [{"world", :tag_two, 1}]} ->
      #   %{"hello" => MapSet.new([:tag]), "world" => MapSet.new([:tag_two])}
      |> Enum.map(fn {to, list} ->
        {to, Enum.map(list, fn {_, tag, _} -> tag end) |> MapSet.new}
      end)
      # calculate the score sum for map entries
      # example:
      #   %{"hello" => MapSet.new([:tag]), "world" => MapSet.new([:tag_two])} ->
      #   %{"hello" => 2, "world" => 1}
      |> Enum.map(fn {to, tags} ->
        considering = MapSet.intersection(tags, tag_set)
        score = Enum.reduce(considering, 1,
          fn tag, acc -> acc + Map.get(tag_scores, tag) end)
        {to, score}
      end) |> Enum.into(%{})
  end

  @spec train(model :: Markov.model_reference, tokens :: [term()], tags :: [term()])
    :: :ok
  def train(model, tokens, tags) do
    options = CubDB.get(model, :options)
    order = options[:order]

    # append `order` `:start` tokens and one `:"$_end"` token
    # example for order=2:
    #   ["Hello,", "World!"] ->
    #   [:"$_start", :"$_start", "Hello,", "World!", :"$_end"]
    tokens = if options[:type] == :hidden do
      tokens = Enum.map(tokens, fn tok -> {tok, Markov.DictionaryHolder.get_type(tok)} end)
      Enum.map(0..(order - 1), fn _ -> {:"$_start", :"$_start"} end) ++ tokens ++ [{:"$_end", :"$_end"}]
    else
      Enum.map(0..(order - 1), fn _ -> :"$_start" end) ++ tokens ++ [:"$_end"]
    end

    CubDB.transaction(model, fn tx ->
      # obtain lists of `order + 1' tokens
      # example for order=2:
      #   [:"$_start", :"$_start", "Hello,", "World!", :"$_end"] ->
      #   [
      #     [:"$_start", :"$_start", "Hello,"],
      #     [:"$_start", "Hello,", "World!"],
      #     ["Hello,", "World!", :"$_end"]
      #   ]
      tx = Enum.reduce(Markov.ListUtil.overlapping_stride(tokens, order + 1), tx, fn bit, tx ->
        # all tokens except the last one tell what state a connection must be made from;
        # the last token tells what state that connection should be made to
        # example:
        #   [:"$_start", :"$_start", "Hello,"] ->
        #   from = [:"$_start", :"$_start"]
        #   to = "Hello,"
        from = Enum.slice(bit, 0..-2)
        to = Enum.at(bit, -1)

        # the generator will succeedingly update its state based on the
        # connections we save here. for example, if it takes the connection from
        # the example above, it will transform its state like this:
        #   [:"$_start", :"$_start"] ->
        #   [:"$_start", "Hello,"]
        # and will then seek a connection based on this new state on the next step

        # sanitize tokens
        from = cond do
          options[:sanitize_tokens] ->
            Enum.map(from, &Markov.TextUtil.sanitize_token/1)
          options[:type] == :hidden ->
            Enum.map(from, fn {_, type} -> type end)
          true ->
            from
        end

        # save connections
        Enum.reduce(tags, tx, fn tag, tx ->
          freq = CubDB.Tx.get(tx, {from, tag, to}, 0) + 1
          CubDB.Tx.put(tx, {from, tag, to}, freq)
        end)
      end)

      {:commit, tx, :ok}
    end)
  end

  @spec generate(model :: Markov.model_reference, tag_query :: Markov.tag_query)
    :: {:ok, [term()]} | {:error, term()}
  def generate(model, tag_query) do
    options = CubDB.get(model, :options)
    order = options[:order]
    initial_state = Enum.map(0..(order - 1), fn _ -> :"$_start" end)
    CubDB.with_snapshot(model, fn snap ->
      walk_chain(snap, [], initial_state, 100, tag_query)
    end)
  end

  @spec walk_chain(snap :: CubDB.Snapshot.t, acc :: [term()], state :: [term()], limit :: non_neg_integer(), tag_query :: Markov.tag_query)
    :: {:ok, [term()]} | {:error, term()}
  def walk_chain(snap, acc, state, limit, tag_query) do
    options = CubDB.Snapshot.get(snap, :options)
    case next_token(snap, state, tag_query) do
      # limit reached
      _ when limit <= 0 -> {:ok, acc}
      # end conditions
      {:ok, :"$_end"} -> {:ok, acc}
      {:ok, {:"$_end", :"$_end"}} -> {:ok, acc}
      # error condition
      {:error, err} -> {:error, err}
      # next token
      {:ok, next} ->
        # in the case of hidden chains, two different tokens will be added to
        # the accumulator and the state
        {to_acc, to_state} = if options[:type] == :hidden do
          next
        else
          {next, next}
        end
        # recurse
        acc = acc ++ [to_acc]
        state = Enum.slice(state, 1..-1) ++ [to_state]
        walk_chain(snap, acc, state, limit - 1, tag_query)
    end
  end

  @spec next_token(snap :: CubDB.Snapshot.t, state :: [term()], tag_query :: Markov.tag_query)
    :: {:ok, term()} | {:error, term()}
  def next_token(snap, state, tag_query) do
    options = CubDB.Snapshot.get(snap, :options)

    # sanitize tokens
    state = if options[:sanitize_tokens] do
      Enum.map(state, &Markov.TextUtil.sanitize_token/1)
    else state end

    # because tags can either be atoms or tuples,
    # by setting min_key to {state, 0, 0} and max_key to {state, "", 0} we
    # can match the pattern {state, _, _} because of the comparison order:
    # int < atom < tuple < bitstring
    rows = CubDB.Snapshot.select(snap, min_key: {state, 0, 0}, max_key: {state, "", 0})
      |> Stream.map(fn {{^state, tag, to}, freq} -> {to, tag, freq} end)
      |> Enum.into([])
      |> apply_shifting(options[:shift_probabilities])

    # multiply frequencies by scores
    scores = process_scores(rows, tag_query)
    rows = rows |> Enum.map(fn {to, _, frequency} ->
      {to, frequency * Map.get(scores, to)}
    end)

    case length(rows) do
      0 -> {:error, {:no_connections, state}}
      _ ->
        # select a random row accounting for probabilities
        sum = rows |> Enum.map(fn {_, freq} -> freq end) |> Enum.sum
        result = probabilistic_select(:rand.uniform(sum) - 1, rows, sum)
        {:ok, result}
    end
  end

  @spec probabilistic_select(integer(), list({any(), integer()}), integer(), integer()) :: any()
  defp probabilistic_select(number, _choices = [{name, add} | tail], sum, acc \\ 0) do
    if (number >= acc) and (number < acc + add) do
      name
    else
      probabilistic_select(number, tail, sum, acc + add)
    end
  end

  @doc "Adjusts the probability of one connection"
  defn adjust_one_prob(param_tensor) do
    i          = Nx.gather(param_tensor, Nx.tensor([[0]])) |> Nx.squeeze
    peak       = Nx.gather(param_tensor, Nx.tensor([[1]])) |> Nx.squeeze
    peak_prob  = Nx.gather(param_tensor, Nx.tensor([[2]])) |> Nx.squeeze
    first_prob = Nx.gather(param_tensor, Nx.tensor([[3]])) |> Nx.squeeze
    ratio      = Nx.gather(param_tensor, Nx.tensor([[4]])) |> Nx.squeeze
    len        = Nx.gather(param_tensor, Nx.tensor([[5]])) |> Nx.squeeze

    power = Nx.tensor(1.7, type: :f32)

    # https://www.desmos.com/calculator/mq3qjg8zpm
    result = cond do
      i < peak ->
        offset = (first_prob / (ratio ** power))
        coeff = (peak_prob - (peak_prob * ratio / (ratio ** power + 1))) / (peak ** ratio)
        (coeff * (i ** ratio)) + offset

      i == peak -> peak_prob

      i > peak ->
        coeff = peak_prob / ((len - peak) ** (1 / ratio))
        coeff * ((-i + len - 1) ** (1 / ratio))

      # never reached
      true -> Nx.Constants.nan
    end

    # round off and convert scalar to {1}-shape
    Nx.round(result) |> Nx.tile([1])
  end

  @doc "Adjust the probabilities of a batch of connections"
  defn adjust_batch_probs(params) do
    results = Nx.iota({@nx_batch_size}, type: :u32) |> Nx.map(fn _ -> -1 end)

    {_, _, results} = while {i = 0, params, results}, i < @nx_batch_size do
      result = adjust_one_prob(params[i])
        |> Nx.as_type(:u32)

      i_from_params = Nx.gather(params[i], Nx.tensor([[0]]))
        |> Nx.squeeze
        |> Nx.as_type(:u32)

      {i + 1, params, Nx.put_slice(results, [i_from_params], result)}
    end

    results
  end

  @spec apply_shifting([{from :: [term()], tag :: atom() | tuple(), freq :: non_neg_integer()}], do_apply :: boolean())
    :: [{from :: [term()], tag :: atom() | tuple(), freq :: non_neg_integer()}]
  def apply_shifting(rows, _do_apply = false), do: rows
  def apply_shifting(rows, _do_apply = true) do
    # sort rows by their probability
    rows = Enum.sort(rows, fn {_, _, foo}, {_, _, bar} -> foo > bar end)

    # choose the peak
    min_allowed = if length(rows) == 1, do: 0, else: 1
    peak = max(min_allowed, :math.sqrt(length(rows)) * 0.1) |> floor()
    {_, _, peak_prob} = rows |> Enum.at(peak)
    # determine by how much the first most probable path is more likely than
    # the peak
    {_, _, first_prob} = rows |> Enum.at(0)
    ratio = min(first_prob / peak_prob, 5)

    jitted = EXLA.jit(&Markov.ModelActions.adjust_batch_probs/1)
    constant_params = [peak, peak_prob, first_prob, ratio, length(rows)]

    Stream.with_index(rows)
      |> Stream.chunk_every(@nx_batch_size)
      |> Stream.flat_map(fn batch ->
        processed = batch
          |> Enum.map(&elem(&1, 1))
          |> Enum.map(fn idx -> [idx | constant_params] end)
          |> Nx.tensor(type: :f32)
          |> jitted.()
          |> Nx.to_flat_list
        Enum.zip(batch, processed) |> Enum.map(fn {{{to, tag, _}, _}, fq} -> {to, tag, fq} end)
      end)
      |> Enum.into([])
  end
end
