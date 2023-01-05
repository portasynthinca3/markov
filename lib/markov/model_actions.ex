defmodule Markov.ModelActions do
  @moduledoc """
  Performs training, generation and probability shifting. Supposed to only ever
  be used by `Markov.ModelServer`s.
  """

  alias Markov.ModelServer.State
  import Nx.Defn
  @nx_batch_size 1024

  @doc "processes tag scores"
  @spec process_scores([{term(), non_neg_integer(), term()}], Markov.tag_query) :: %{term() => non_neg_integer()}
  def process_scores(rows, tag_scores) do
    tag_set = Map.keys(tag_scores) |> MapSet.new # [:tag]
    rows                                         # [{"hello", 1, :tag}, {"world", 1, :tag_two}]
      |> Enum.group_by(fn {to, _, _} -> to end)  # %{"hello" => [{"hello", 1, :tag}], "world" => [{"world", 1, :tag_two}]}
      |> Enum.map(fn {to, list} ->
        {to, Enum.map(list, fn {_, tag, _} -> tag end) |> MapSet.new}
      end)                                       # %{"hello" => MapSet.new([:tag]), "world" => MapSet.new([:tag_two])}
      |> Enum.map(fn {to, tags} ->
        considering = MapSet.intersection(tags, tag_set)
        score = Enum.reduce(considering, 0,
          fn tag, acc -> acc + Map.get(tag_scores, tag) end)
        {to, score + 1}
      end) |> Enum.into(%{})                     # %{"hello" => 1, "world" => 0}
  end

  @spec train(state :: State.t(), tokens :: [term()], tags :: [term()]) :: :ok
  def train(state, tokens, tags) do
    order = state.options[:order]
    tokens = Enum.map(0..(order - 1), fn _ -> :start end) ++ tokens ++ [:end]

    Markov.ListUtil.overlapping_stride(tokens, order + 1)
      |> Flow.from_enumerable
      |> Flow.map(fn bit ->
        from = Enum.slice(bit, 0..-2)
        to = Enum.at(bit, -1)

        # sanitize tokens
        from = if state.options[:sanitize_tokens] do
          Enum.map(from, &Markov.TextUtil.sanitize_token/1)
        else from end

        for tag <- tags do
          keys = [from, tag, to]
          case Sidx.select(state.main_table, keys) do
            {:ok, []} -> Sidx.insert(state.main_table, keys, 1)
            {:ok, [{[], val}]} -> Sidx.insert(state.main_table, keys, val + 1)
          end
        end
      end)
      |> Flow.run

    :ok
  end

  @spec generate(State.t(), Markov.tag_query()) :: {{:ok, [term()]} | {:error, term()}, State.t()}
  def generate(state, tag_query) do
    order = state.options[:order]
    initial_queue = Enum.map(0..(order - 1), fn _ -> :start end)
    walk_chain(state, [], initial_queue, 100, tag_query)
  end

  @spec walk_chain(State.t(), [term()], [term()], non_neg_integer(), Markov.tag_query())
    :: {{:ok, [term()]} | {:error, term()}, State.t()}
  def walk_chain(state, acc, queue, limit, tag_query) do
    case next_state(state, queue, tag_query) do
      _ when limit <= 0 -> {{:ok, acc}, state}
      {:ok, :end, state} -> {{:ok, acc}, state}
      {:error, err, state} -> {{:error, err}, state}
      {:ok, next, state} ->
        walk_chain(state, acc ++ [next], Enum.slice(queue, 1..-1) ++ [next], limit - 1, tag_query)
    end
  end

  @spec next_state(State.t(), [term()], Markov.tag_query())
    :: {:ok, term(), State.t()} | {:error, term(), State.t()}
  def next_state(state, current, tag_query) do
    current = if state.options[:sanitize_tokens] do
      Enum.map(current, &Markov.TextUtil.sanitize_token/1)
    else current end

    case Sidx.select(state.main_table, [current]) do
      {:ok, []} -> {:error, {:no_matches, current}, state}
      {:ok, rows} ->
        rows = rows |> Enum.map(fn {[to, tag], freq} -> {to, tag, freq} end)
        rows = if state.options[:shift_probabilities], do: apply_shifting(rows), else: rows
        scores = process_scores(rows, tag_query)
        rows = rows |> Enum.map(fn {to, _, frequency} ->
          {to, frequency * Map.get(scores, to)}
        end)
        sum = rows
          |> Enum.map(fn {_, frequency} -> frequency end)
          |> Enum.sum
        result = probabilistic_select(:rand.uniform(sum) - 1, rows, sum)
        {:ok, result, state}
    end
  end

  @spec probabilistic_select(integer(), list({any(), integer()}), integer(), integer()) :: any()
  defp probabilistic_select(number, [{name, add} | tail] = _choices, sum, acc \\ 0) do
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

      # hopefully never reached
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

  @spec apply_shifting([{[term()], non_neg_integer()}])
    :: [{[term()], non_neg_integer()}]
  defp apply_shifting(rows) do
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
