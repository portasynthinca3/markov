defmodule ShiftTest do
  use ExUnit.Case, async: true
  import Markov

  test "prompts" do
    File.rm_rf("model_shift")
    {:ok, model} = Markov.load("model_shift", store_log: [], shift_probabilities: true)
    on_exit(fn ->
      Markov.unload(model)
      File.rm_rf("model_shift")
    end)

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
  end
end
