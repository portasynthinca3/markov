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
  [{:markov, "~> 2.0"}]
end
```

Unlike Markov 1.x, this version has very strong opinions on how you should create and persist your models.

Example workflow (click [here](https://hexdocs.pm/markov/api-reference.html) for full docs):
```elixir
# the model is to be stored under /base/directory/model_name
# the model will be created using specified options if not found
{:ok, model} = Markov.load("/base/directory", "model_name", sanitize_tokens: true, store_history: [:train])

# train using four strings
{:ok, _} = Markov.train(model, "hello, world!")
{:ok, _} = Markov.train(model, "example string number two")
{:ok, _} = Markov.train(model, "hello, Elixir!")
{:ok, _} = Markov.train(model, "fourth string")

# generate text
{:ok, text} = Markov.generate_text(model)
IO.inspect(text)

# unload model from RAM
Markov.unload(model)

# these will return errors because the model is unloaded
# Markov.generate_text(model)
# Markov.train(model, "hello, world!")

# load the model again
{:ok, model} = Markov.load("/base/directory", "model_name")

# enable probability shifting and generate text
:ok = Markov.configure(model, shift_probabilities: true)
{:ok, text} = Markov.generate_text(model)
IO.inspect(text)

# print uninteresting stats
model |> Markov.dump_partition(0) |> IO.inspect
model |> Markov.read_log |> IO.inspect

# this will also write our new just-set option
Markov.unload(model)
```

## Credits
  - [The English dictionary in a CSV format](https://www.bragitoff.com/2016/03/english-dictionary-in-csv-format/)
