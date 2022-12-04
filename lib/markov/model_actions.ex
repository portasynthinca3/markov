defmodule Markov.ModelActions do
  @moduledoc """
  Performs training, generation and probability shifting. Supposed to only ever
  be used by `Markov.ModelServer`s.
  """

  alias Markov.ModelServer.State
  import Markov.ModelServer, only: [open_partition!: 2]
  import Nx.Defn
  @nx_batch_size 1024

  # WARNING: match specifications ahead

  @doc "tag query to match specification"
  @spec tq2ms([term()], Markov.tag_query()) :: :ets.match_spec()
  def tq2ms(from, query), do: [{
    {from, :"$1", :"$2", :"$3"},
    [tq2msc(query)],
    [{{:"$2", :"$3"}}]
  }]

  @doc "tag query to match spec condition"
  @spec tq2msc(Markov.tag_query()) :: term()
  def tq2msc(true), do: {:==, 1, 1}
  def tq2msc({:not, x}), do: {:not, tq2msc(x)}
  def tq2msc({x, :or, y}), do: {:orelse, tq2msc(x), tq2msc(y)}
  def tq2msc({x, :score, _y}), do: tq2msc(x)
  def tq2msc(tag), do: {:==, :"$1", {:const, tag}}

  @doc "processes {_, :score, _} tag queries"
  def process_scores(from, rows, {_, :score, queries}, table) do
    to_sets = for {query, score} <- queries do
      ms = [{
        {from, :"$1", :"$2", :_},
        [tq2msc(query)],
        [:"$2"]
      }]
      {:ets.select(table, ms) |> MapSet.new, score}
    end

    rows_tos = MapSet.new(for {to, _} <- rows, do: to)

    Enum.reduce(to_sets, %{}, fn {set, score}, acc ->
      MapSet.intersection(rows_tos, set)
        |> Enum.reduce(acc, fn to, acc ->
          previous = Map.get(acc, to, 0)
          Map.put(acc, to, previous + score)
        end)
    end)
  end

  def process_scores(_, _, _, _), do: %{}

  @spec train(state :: State.t(), tokens :: [term()], tags :: [term()]) :: State.t()
  def train(state, tokens, tags) do
    order = state.options[:order]
    tokens = Enum.map(0..(order - 1), fn _ -> :start end) ++ tokens ++ [:end]
    Markov.ListUtil.overlapping_stride(tokens, order + 1) |> Enum.reduce(state, fn bit, state ->
      from = Enum.slice(bit, 0..-2)
      to = Enum.at(bit, -1)

      # sanitize tokens
      from = if state.options[:sanitize_tokens] do
        Enum.map(from, &Markov.TextUtil.sanitize_token/1)
      else from end

      partition = HashRing.key_to_node(state.ring, from)
      state = open_partition!(state, partition) # doesn't do anything if already open
      {table, timeout_pid} = Map.get(state.open_partitions, partition)
      send(timeout_pid, :defer) # signal usage

      for tag <- tags do
        case :ets.match(table, {from, tag, to, :"$1"}) do
          [] -> :ets.insert(table, {from, tag, to, 1})
          [[previous]] ->
            :ets.match_delete(table, {from, tag, to, previous})
            :ets.insert(table, {from, tag, to, previous + 1})
        end
      end
      %{state | total_links: state.total_links + 1}
    end)
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

    partition = HashRing.key_to_node(state.ring, current)
    {table, timeout_pid} = Map.get(state.open_partitions, partition)
    state = open_partition!(state, partition)
    send(timeout_pid, :defer)

    case :ets.select(table, tq2ms(current, tag_query)) do
      [] -> {:error, {:no_matches, current}, state}
      rows ->
        rows = if state.options[:shift_probabilities], do: apply_shifting(rows), else: rows
        scores = process_scores(current, rows, tag_query, table)
        rows = rows |> Enum.map(fn {to, frequency} ->
          score = Map.get(scores, to, 0) + 1
          {to, frequency * score}
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

    # linear approximation
    # result = cond do
    #   i < peak ->
    #     a = peak_prob / ratio
    #     k = (peak_prob - a) / peak
    #     k * i + a
    #
    #   i == peak -> peak_prob
    #
    #   i > peak ->
    #     last = len - 1
    #     peak_to_last = last - peak
    #     k = -Nx.min((ratio - 1) / peak_to_last, peak_prob / peak_to_last)
    #     a = -k + peak_prob
    #     k * i + a
    #
    #   # hopefully never reached
    #   true -> Nx.Constants.nan
    # end

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
    rows = Enum.sort(rows, fn {_, foo}, {_, bar} -> foo > bar end)

    # choose the peak
    min_allowed = if length(rows) == 1, do: 0, else: 1
    peak = max(min_allowed, :math.sqrt(length(rows)) * 0.1) |> floor()
    {_, peak_prob} = rows |> Enum.at(peak)
    # determine by how much the first most probable path is more likely than
    # the peak
    {_, first_prob} = rows |> Enum.at(0)
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
        Enum.zip(batch, processed) |> Enum.map(fn {{{k, _}, _}, v} -> {k, v} end)
      end)
      |> Enum.into([])
  end
end
