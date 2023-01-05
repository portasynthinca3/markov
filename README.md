# Markov
<img align="right" src="logo/logo.png" onerror="this.src = 'assets/logo.png'">

Text generation library based on nth-order Markov chains

![Hex.pm](https://img.shields.io/hexpm/v/markov)
![Hex.pm](https://img.shields.io/hexpm/dd/markov)

## Features
  - **Token sanitation** (optional): ignores letter case and punctuation when switching states, but still keeps the output as-is
  - **Operation history** (optional): recalls the operations it was instructed to perform, incl. past training data
  - **Probability shifting** (optional): gives less popular generation paths more chance to get used, which makes the output more original but may produce nonsense
  - **Tagging** (optional): you can tag your source data to be queried later by aggregating those tags in any way you want, kind of like a database
  - **Context awareness** (optional) grants your model the ability to answer questions given to it provided training data is good enough
  - **Managed disk storage**
  - **Transparent fragmentation** reduces RAM usage and loading times with huge models

## Usage
In `mix.exs`:
```elixir
defp deps do
  [{:markov, "~> 4.0"}]
end
```

Unlike Markov 1.x, this version has very strong opinions on how you should create and persist your models (that differs from 2.x and 3.x).

Example workflow (click [here](https://hexdocs.pm/markov/api-reference.html) for full docs):
```elixir
# The model will be stored under this path
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

# these will return errors because the model is unloaded
# Markov.generate_text(model)
# Markov.train(model, "hello, world!")

# load the model again
{:ok, model} = Markov.load("./model_path")

# enable probability shifting and generate text
:ok = Markov.configure(model, shift_probabilities: true)
{:ok, text} = Markov.generate_text(model)
IO.puts(text)

# print uninteresting stats
model |> Markov.dump_partition(0) |> IO.inspect
model |> Markov.read_log |> IO.inspect

# this will also write our new just-set option
Markov.unload(model)
```

## Credits
  - [The English dictionary in a CSV format](https://www.bragitoff.com/2016/03/english-dictionary-in-csv-format/)
