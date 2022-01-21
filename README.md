# Markov
Text generation library based on second-order Markov chains

![Hex.pm](https://img.shields.io/hexpm/v/markov)
![Hex.pm](https://img.shields.io/hexpm/dd/markov)

## Usage
In `mix.exs`:
```elixir
defp deps do
  [{:markov, "~> 1.2"}]
end
```

## API

### `train/2`
Trains the chain using provided text.

**Example**:
```elixir
chain = %Markov{}
    |> Markov.train("hello, world!")
    |> Markov.train("example string number two")
    |> Markov.train("hello, Elixir!")
    |> Markov.train("fourth string")
```

### `generate_text/3`
Generates text using the chain, prepends a specified string and assumes a specific starting state.
The last two arguments are optional.

**Examples**:
```elixir
iex> %Markov{} |>
...> Markov.train("hello, world!") |>
...> Markov.generate_text()
"hello, world!"

iex> %Markov{} |>
...> Markov.train("hello, world!") |>
...> Markov.generate_text("", [:start, "hello,"])
"world!"
```

### `next_state/3`
Predicts the next state from two last states.

**Examples**:
```elixir
iex> %Markov{} |>
...> Markov.train("1 2 3 4 5") |>
...> Markov.next_state(["2", "3"])
"4"

iex> %Markov{} |>
...> Markov.train("1 2") |>
...> Markov.next_state([:start, :start])
"1"
```

### `forget_token/2`
Removes a token from the chain.

**Examples**:
```elixir
iex> %Markov{} |>
...> Markov.train("a b c") |>
...> Markov.forget_token("b") |>
...> Markov.generate_text()
"a"
```

### Sanitization mode
Ignores leading and trailing non-word characters, as well as the case, in textual tokens.

**Example**:
```elixir
iex> chain = %Markov{sanitize_tokens: true} |>
...> Markov.train("hello, Elixir world") |>
...> Markov.train("hello Markov chains")
%Markov{
...
}
iex> chain |> Markov.generate_text()
"hello, Markov chains"
iex> chain |> Markov.generate_text()
"hello Elixir world"
```

### `enable_token_sanitization/1`
Enables token sanitization on a chain. This mode can't be disabled once it has been enabled.

### Shift mode
In this mode, the generation routine dampens the rate of more popular tokens and gives less common generation paths more chance to get used. Enabling this mode may help if you feel like this library is repeating original data verbatim or almost verbatim. Output may make less sense with this mode turned on.

**Example**:
```elixir
iex> chain = %Markov{shift: true} |>
...> Markov.train("1 2 3 4 5") |>
...> Markov.train("1 2 3 4 5") |>
...> Markov.train("1 2 3 4 5") |>
...> Markov.train("1 3 4 5") |>
%Markov{
...
}
iex> chain |> Markov.generate_text()
"1 3 4 5"
```
