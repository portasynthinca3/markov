# Markov
Text generation library based on second-order Markov chains

## Demo
```
$ iex -S mix
Erlang/OTP 22 [erts-10.4.4] [source] [64-bit] [smp:4:4] [ds:4:4:10] [async-threads:1] [hipe]

Compiling 2 files (.ex)
Generated markov app
Interactive Elixir (1.12.2) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)> Markov.Demo.generate_shakespeare
Since that my two ears
thee, hind!
deliver you.
DROMIO OF SYRACUSE
Pleaseth you walk in to see their gossiping?
For, ere the weary sun set in my shape.
In Ephesus I am advised what I think.
Exeunt
DROMIO OF SYRACUSE
Give her this key, and tell her, in the teeth?
A back-friend, a shoulder-clapper, one that
Neither: he took this place for sanctuary,
BALTHAZAR
ANTIPHOLUS
...... (100 lines in total)
```

## Usage
In `mix.exs`:
```elixir
defp deps do
  [{:markov, "~> 0.1"}]
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
iex> chain |> Markov.generate_text()
```

### `enable_token_sanitization/1`
Enables token sanitization on a chain. This mode can't be disabled once it has been enabled.