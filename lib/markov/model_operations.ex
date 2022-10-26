defmodule Markov.ModelActions do
  @moduledoc """
  Performs training, generation and probability shifting. Supposed to only ever
  be used by `Markov.ModelServer`s.
  """

  alias Markov.ModelServer.State
  import Markov.ModelServer, only: [open_partition!: 2]

  @spec train(state :: State.t(), tokens :: [term()]) :: :ok
  def train(state, tokens) do
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
      links_from = :dets.lookup({:partition, state.name, partition}, from)
      links_from = case links_from do
        [] -> %{}
        [{^from, links}] -> links
      end

      new_weight = if links_from[to] == nil, do: 1, else: links_from[to] + 1
      links_from = Map.put(links_from, to, new_weight)
      :dets.insert({:partition, state.name, partition}, {from, links_from})
      state
    end)
  end

  def generate(state) do
    order = state.options[:order]
    initial_queue = Enum.map(0..(order-1), fn _ -> :start end)
    walk_chain(state, [], initial_queue, 100)
  end

  def walk_chain(state, acc, queue, limit) do
    next = next_state(state, queue)
    if next == :end or limit <= 0 do
      acc
    else
      walk_chain(state, acc ++ [next], Enum.slice(queue, 1..-1) ++ [next], limit - 1)
    end
  end

  def next_state(state, current) do
    current = if state.options[:sanitize_tokens] do
      Enum.map(current, &Markov.TextUtil.sanitize_token/1)
    else current end

    partition = HashRing.key_to_node(state.ring, current)
    state = open_partition!(state, partition)
    send(Map.get(state.open_partitions, partition), :defer)
    [{_, links}] = :dets.lookup({:partition, state.name, partition}, current)
    links = Enum.into(links, [])

    sum = Enum.unzip(links)
      |> Tuple.to_list
      |> List.last
      |> Enum.sum

    :rand.uniform(sum) - 1 |> probabilistic_select(links, sum)
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
