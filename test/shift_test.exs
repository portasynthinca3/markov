defmodule ShiftTest do
  use ExUnit.Case
  import Markov

  test "prompts" do
    File.rm_rf("model_test")
    {:ok, model} = Markov.load("model_test", store_log: [], shift_probabilities: true)

    assert Markov.train(model, "hello world") == :ok
    assert Markov.train(model, "hello world") == :ok
    assert Markov.train(model, "hello world") == :ok
    assert Markov.train(model, "hello elixir") == :ok
    assert Markov.train(model, "hello elixir") == :ok

    %{{:ok, "hello world"} => world, {:ok, "hello elixir"} => elixir} =
      0..999
        |> Enum.map(fn _ -> generate_text(model) end)
        |> Enum.frequencies
    assert world >= 400 and world <= 600
    assert elixir >= 400 and elixir <= 600
    assert world + elixir == 1000

    Markov.unload(model)
  end
end
