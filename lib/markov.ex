defmodule Markov do
  @moduledoc """
  Markov-chain-based trained text generator implementation.
  Next token prediction uses two previous tokens.
  """

  defstruct links: %{[:start, :start] => %{end: 1}},
            sanitize_tokens: false,
            shift: false

  # Conditionally sanitizes a token list
  @spec cond_sanitize_tokens([any()], %Markov{}) :: [any()]
  defp cond_sanitize_tokens(tokens, chain) do
    if chain.sanitize_tokens do
      tokens |> Enum.map(&Markov.TextUtil.sanitize_token/1)
    else tokens end
  end

  # Conditionally shifts probabilities
  @spec cond_shift_probs(%{[any()] => any()}, %Markov{}) :: %{[any()] => any()}
  def cond_shift_probs(links, %Markov{shift: shift}) do
    if shift and map_size(links) >= 2 do
      # sort links by their probability
      links = links
        |> Enum.into([])
        |> Enum.sort(fn {_, foo}, {_, bar} -> foo > bar end)

      # choose the peak
      peak = max(1, length(links) * 0.10) |> floor()
      {_, peak_prob} = Enum.at(links, peak)
      # determine by how much the first most probable path
      # is more likely than the peak
      {_, first_prob} = Enum.at(links, 0)
      ratio = min(first_prob / peak_prob, 10)

      # https://www.desmos.com/calculator/mq3qjg8zpm
      # fun fact: this is literally the first time ever in my
      # 8 year long programming career that i actually had to
      # use "real" maths

      exp = 1.7
      links = for i <- 0 .. length(links)-1 do
        {k, _} = Enum.at(links, i)
        {k, v} = cond do
          # massively dampen probabilities before the peak
          i < peak ->
            offset = (first_prob / (ratio ** exp))
            coeff = (peak_prob - (peak_prob * ratio / (ratio ** exp + 1))) / (peak ** ratio)
            {k, (coeff * (i ** ratio)) + offset}
          # leave the peak as is
          i == peak ->
            {k, peak_prob}
          # gradual fall-off
          i > peak ->
            len = length(links)
            coeff = peak_prob / ((len - peak - 1) ** (1 / ratio))
            {k, coeff * ((-i + len - 1) ** (1 / ratio))}
        end
        # last step: rounding
        {k, round(v)}
      end

      links |> Enum.into(%{})
    else links end
  end

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
      from = [first, second] |> cond_sanitize_tokens(chain)
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
  Removes a `token` from all generation paths `chain` could produce.

  Returns the modifier chain

  ## Example
      iex> %Markov{} |>
      ...> Markov.train("a b c") |>
      ...> Markov.forget_token("b") |>
      ...> Markov.generate_text()
      "a"
  """
  @spec forget_token(%Markov{}, any()) :: %Markov{}
  def forget_token(%Markov{}=chain, token) do
    # sanitize the token
    token = if chain.sanitize_tokens do
      token |> Markov.TextUtil.sanitize_token
    else token end
    # remove links that point to the token
    %{chain | links: chain.links |> Enum.map(fn
      {[_, _]=k, v} ->
        {k, Enum.filter(v, fn {k, _} -> k != token end) |> Enum.into(%{})}
      {k, v} -> {k, v}
    end) |> Enum.into(%{})
    # terminate states that point nowhere
    |> Enum.map(fn
      {k, %{}=map} when map_size(map) == 0 ->
        {k, %{end: 1}}
      {k, v} -> {k, v}
    end) |> Enum.into(%{})}
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
    # sanitize state
    current = current |> cond_sanitize_tokens(chain)
    # get links from current state
    # (enforce constant order by converting to proplist)
    links = chain.links[current]
      |> cond_shift_probs(chain)
      |> Enum.into([])

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
  two states were `[state1, state2]=state`. The amount of
  the resulting token list is limited by `limit`.

  Returns the generated list.

  ## Example
      iex> %Markov{} |> Markov.train([:a, :b, :c]) |> Markov.generate_tokens()
      [:a, :b, :c]

      iex> %Markov{} |> Markov.train([:a, :b, :c]) |>
      ...> Markov.generate_tokens([], [:a, :b])
      [:c]
  """
  @spec generate_tokens(%Markov{}, [any()], [any()], integer()) :: String.t()
  def generate_tokens(%Markov{}=chain, acc \\ [], state \\ [:start, :start], limit \\ 100) do
    # iterate through states until :end
    new_state = next_state(chain, state)
    if new_state == :end or limit <= 0 do
      acc
    else
      generate_tokens(chain, acc ++ [new_state], [state |> Enum.at(1), new_state], limit - 1)
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

  @doc """
  Enables token sanitization on a `chain`.
  When this mode is enabled, the chain doesn't understand the difference similar textual tokens.
  This mode can't be disabled once it has been enabled.

  Returns the modified chain.
  """
  @spec enable_token_sanitization(%Markov{}) :: %Markov{}
  def enable_token_sanitization(%Markov{}=chain) do
    sanitize = fn t -> t |> Enum.map(&Markov.TextUtil.sanitize_token/1) end

    find_similar_states = fn [_,_]=state ->
      state = state |> sanitize.()
      chain.links |> Map.keys |> Enum.filter(fn s ->
        s |> sanitize.() == state
      end)
    end

    combine_states = fn states ->
      states |> Enum.reduce(%{}, fn state, acc ->
        Map.merge(acc, state, fn _, v1, v2 -> v1 + v2 end)
      end)
    end

    {new_links, _} = chain.links |> Map.keys |> Enum.reduce({%{}, []} , fn k, {map, ignore} ->
      sanitized = sanitize.(k)
      unless sanitized in ignore do
        similar = find_similar_states.(k) # also includes this one
        combined = similar |> Enum.map(fn k -> Map.get(chain.links, k) end) |> combine_states.()
        map = map |> Map.put(sanitized, combined)
        {map, ignore ++ [sanitized]}
      else
        {map, ignore}
      end
    end)

    %{chain | links: new_links, sanitize_tokens: true}
  end
end
