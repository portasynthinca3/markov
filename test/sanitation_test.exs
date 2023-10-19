defmodule SanitationTest do
  use ExUnit.Case, async: true

  test "sanitation" do
    File.rm_rf("model_sanitation")
    {:ok, model} = Markov.load("model_sanitation", store_log: [], sanitize_tokens: true)
    on_exit(fn ->
      Markov.unload(model)
      File.rm_rf("model_sanitation")
    end)

    Markov.train(model, "hello world")
    Markov.train(model, "hello!!!!!!!!! elixir")
    Markov.train(model, "??hello!!! Elixir")

    entries = (for _ <- 0..1000, do: Markov.generate_text(model))
      |> Enum.map(fn {:ok, t} -> t end)
      |> Enum.uniq

    assert "hello world" in entries
    assert "hello!!!!!!!!! world" in entries
    assert "??hello!!! world" in entries

    assert "hello elixir" in entries
    assert "hello!!!!!!!!! elixir" in entries
    assert "??hello!!! elixir" in entries

    assert "hello Elixir" in entries
    assert "hello!!!!!!!!! Elixir" in entries
    assert "??hello!!! Elixir" in entries
  end
end
