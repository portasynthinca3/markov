defmodule TagTest do
  use ExUnit.Case
  import Markov

  test "simple tag query" do
    File.rm_rf("./test/model_tq")
    {:ok, model} = load("./test", "model_tq")

    assert train(model, "1", [:one]) == {:ok, :done}
    assert train(model, "2", [:two]) == {:ok, :done}
    assert generate_text(model, :one) == {:ok, "1"}
    assert generate_text(model, :two) == {:ok, "2"}

    unload(model)
  end

  test ":not tag query" do
    File.rm_rf("./model_tq")
    {:ok, model} = load("./test", "model_tq")

    assert train(model, "1", [:one]) == {:ok, :done}
    assert train(model, "2", [:two]) == {:ok, :done}
    assert generate_text(model, {:not, :one}) == {:ok, "2"}
    assert generate_text(model, {:not, :two}) == {:ok, "1"}

    unload(model)
  end

  test ":or tag query" do
    File.rm_rf("./model_tq")
    {:ok, model} = load("./test", "model_tq")

    assert train(model, "1", [:one]) == {:ok, :done}
    assert train(model, "2", [:two]) == {:ok, :done}
    assert train(model, "3", [:three]) == {:ok, :done}
    assert train(model, "4", [:four]) == {:ok, :done}
    assert generate_text(model, {:one, :or, :three}) in [{:ok, "1"}, {:ok, "3"}]
    assert generate_text(model, {:two, :or, :three}) in [{:ok, "2"}, {:ok, "3"}]
    assert generate_text(model, {:two, :or, :four}) in [{:ok, "2"}, {:ok, "4"}]

    unload(model)
  end
end
