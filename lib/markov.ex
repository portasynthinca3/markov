defmodule Markov do
  @moduledoc """
  Markov-chain-based trained text generator implementation.
  Next token prediction uses two previous tokens.
  """

  defstruct links: %{[:start, :start] => %{end: 1}, end: %{}}

  @doc """
  Trains `chain` using `text` or a list of `tokens`.

  Returns the modified chain.

  ## Example
      chain = %Markov{}
          |> Markov.train("hello, world!")
          |> Markov.train("example string number two")
          |> Markov.train("hello, Elixir!")
          |> Markov.train("fourth string")

      chain = %Markov{}
          |> Markov.train(["individual tokens", :can_be, 'arbitrary terms'])
  """
  @spec train(%Markov{}, String.t() | [any()]) :: %Markov{}
  def train(%Markov{}=chain, text) when is_binary(text) do
    tokens = String.split(text)
    train(chain, tokens)
  end

  def train(%Markov{}=chain, tokens) when is_list(tokens) do
    # add start and end tokens
    tokens = [:start, :start] ++ tokens ++ [:end]

    # adjust link weights
    new_links = Enum.reduce Markov.ListUtil.ttuples(tokens), chain.links, fn {first, second, third}, acc ->
      from = [first, second]
      to = third
      links_from = acc[from]
      links_from = if links_from == nil do %{} else links_from end
      if links_from[to] == nil do
        Map.put(acc, from, Map.put(links_from, to, 1))
      else
        Map.put(acc, from, Map.put(links_from, to, links_from[to] + 1))
      end
    end

    # forcefully break the start -> end link
    new_links = Map.put(new_links, [:start, :start], Map.delete(new_links[[:start, :start]], :end))
    chain = %{chain | links: new_links}

    chain
  end

  @doc """
  Predicts the next state of a `chain` assuming `current` state.

  Note: current state conists of two tokens.

  Returns the next predicted state.

  ## Example
      iex> %Markov{} |> Markov.train("1 2 3 4 5") |> Markov.next_state(["2", "3"])
      "4"

      iex> %Markov{} |> Markov.train("1 2") |> Markov.next_state([:start, :start])
      "1"

      iex> %Markov{} |> Markov.train([:a, :b, :c]) |> Markov.next_state([:a, :b])
      :c
  """
  @spec next_state(%Markov{}, any()) :: any()
  def next_state(%Markov{}=chain, current) do
    # get links from current state
    # (enforce constant order by converting to proplist)
    links = chain.links[current] |> Enum.into([])

    # do the magic
    sum = Enum.unzip(links)
        |> Tuple.to_list
        |> List.last
        |> Enum.sum
    :rand.uniform(sum) - 1 |> probabilistic_select(links, sum)
  end

  @doc """
  Generates a list of tokens using the `chain`

  Optionally prepends `acc` to it and assumes the previous
  two states were `[state1, state2]=state`.

  Returns the generated list.

  ## Example
      iex> %Markov{} |> Markov.train([:a, :b, :c]) |> Markov.generate_tokens()
      [:a, :b, :c]

      iex> %Markov{} |> Markov.train([:a, :b, :c]) |>
      ...> Markov.generate_tokens([], [:a, :b])
      [:c]
  """
  @spec generate_tokens(%Markov{}, acc :: [any()], [any()]) :: String.t()
  def generate_tokens(%Markov{}=chain, acc \\ [], state \\ [:start, :start]) do
    # iterate through states until :end
    new_state = next_state(chain, state)
    unless new_state == :end do
      generate_tokens(chain, acc ++ [new_state], [state |> Enum.at(1), new_state])
    else
      acc
    end
  end

  @doc """
  Generates a string of text using the `chain`

  Optionally assumes the previous two states were `[state1, state2]=state`.

  Returns the generated text.

  ## Example
      iex> %Markov{} |> Markov.train("hello, world!") |> Markov.generate_text()
      "hello, world!"

      iex> %Markov{} |> Markov.train("hello, world!") |>
      ...> Markov.generate_text([:start, "hello,"])
      "world!"
  """
  @spec generate_text(%Markov{}, [any()]) :: String.t()
  def generate_text(%Markov{}=chain, state \\ [:start, :start]) do
    generate_tokens(chain, [], state) |> Enum.join(" ")
  end

  @spec probabilistic_select(integer(), list({any(), integer()}), integer(), integer()) :: any()
  defp probabilistic_select(number, [{name, add} | tail]=_choices, sum, acc \\ 0) do
    if (number >= acc) and (number < acc + add) do
      name
    else
      probabilistic_select(number, tail, sum, acc + add)
    end
  end
end
