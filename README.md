# Markov
Text generation library based on second-order Markov chains

![Hex.pm](https://img.shields.io/hexpm/v/markov)
![Hex.pm](https://img.shields.io/hexpm/dd/markov)

## Usage
In `mix.exs`:
```elixir
defp deps do
  [{:markov, "~> 2.0"}]
end
```

Unlike Markov 1.x, this version has very strong opinions on how you should create and persist the models.

Example workflow:
```elixir
# the model is to be stored under /base/directory/model_name
# the model will be created using specified options if not found
model = Markov.load("/base/directory", "model_name", sanitize_tokens: true, store_training_data: true)

# train using four strings
model
  |> Markov.train("hello, world!")
  |> Markov.train("example string number two")
  |> Markov.train("hello, Elixir!")
  |> Markov.train("fourth string")

# generate text
model |> Markov.generate_text |> IO.inspect

# unload model from RAM
model |> Markov.unload

# this will raise because the model is unloaded
# model |> Markov.generate_text |> IO.inspect
# model |> Markov.train("hello, world!")

# load the model again
model = Markov.load("/base/directory", "model_name")

# enable probability shifting and generate text
model
  |> Markov.set(shift_probabilities: true)
  |> Markov.generate_text |> IO.inspect

# print uninteresting stats
model |> Markov.stats |> IO.inspect

# this will also write our new just-set option
model |> Markov.unload
```

View the full documentation [here](https://hexdocs.pm/markov/api-reference.html)
