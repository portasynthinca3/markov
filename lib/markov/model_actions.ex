defmodule Markov.ModelActions do
  @moduledoc """
  Performs training, generation and probability shifting. Supposed to only ever
  be used by `Markov.ModelServer`s.
  """

  alias Markov.ModelServer.State
  import Markov.ModelServer, only: [open_partition!: 2]

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
      {:dets.select(table, ms) |> MapSet.new, score}
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
      send(Map.get(state.open_partitions, partition), :defer) # signal usage

      for tag <- tags do
        table = {:partition, state.name, partition}
        case :dets.match(table, {from, tag, to, :"$1"}) do
          [] -> :dets.insert(table, {from, tag, to, 1})
          [[previous]] ->
            :dets.match_delete(table, {from, tag, to, previous})
            :dets.insert(table, {from, tag, to, previous + 1})
        end
      end
      state
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
    state = open_partition!(state, partition)
    send(Map.get(state.open_partitions, partition), :defer)

    table = {:partition, state.name, partition}
    case :dets.select(table, tq2ms(current, tag_query)) do
      [] -> {:error, {:no_matches, current}, state}
      rows ->
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
end
