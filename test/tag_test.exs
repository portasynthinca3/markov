defmodule TagTest do
  use ExUnit.Case
  import Markov

  test "simple tag query" do
    nuke("model")
    {:ok, model} = load("model")

    assert train(model, "1", [:one]) == :ok
    assert train(model, "2", [:two]) == :ok
    assert generate_text(model, :one) == {:ok, "1"}
    assert generate_text(model, :two) == {:ok, "2"}

    unload(model)
  end

  test ":not tag query" do
    nuke("model")
    {:ok, model} = load("model")

    assert train(model, "1", [:one]) == :ok
    assert train(model, "2", [:two]) == :ok
    assert generate_text(model, {:not, :one}) == {:ok, "2"}
    assert generate_text(model, {:not, :two}) == {:ok, "1"}

    unload(model)
  end

  test ":or tag query" do
    nuke("model")
    {:ok, model} = load("model")

    assert train(model, "1", [:one]) == :ok
    assert train(model, "2", [:two]) == :ok
    assert train(model, "3", [:three]) == :ok
    assert train(model, "4", [:four]) == :ok
    assert generate_text(model, {:one, :or, :three}) in [{:ok, "1"}, {:ok, "3"}]
    assert generate_text(model, {:two, :or, :three}) in [{:ok, "2"}, {:ok, "3"}]
    assert generate_text(model, {:two, :or, :four}) in [{:ok, "2"}, {:ok, "4"}]

    unload(model)
  end

  test "unknown tag" do
    nuke("model")
    {:ok, model} = load("model")

    assert train(model, "1", [:one]) == :ok
    assert generate_text(model, :two) == {:error, {:no_matches, [:start, :start]}}

    unload(model)
  end
end
