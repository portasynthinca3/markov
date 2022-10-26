defmodule MarkovTest do
  use ExUnit.Case

  test "creating the model" do
    File.rm_rf(Path.join("test", "model_empty"))
    {:ok, model} = Markov.load("test", "model_empty")
    Markov.unload(model)
  end

  test "creating the model in a non-existent dir" do
    assert Markov.load("/hopefully/this/path/doesnt", "exist") == {:error, :enoent}
  end

  test "reconfiguration" do
    {:ok, model} = Markov.load("test", "model_reconfig")
    Markov.configure(model, partition_size: 5000)
    {:ok, config} = Markov.get_config(model)
    Markov.unload(model)
    assert config[:partition_size] == 5000
  end

  test "configuration persistence" do
    {:ok, model} = Markov.load("test", "model_reconfig")
    Markov.configure(model, partition_size: 7500)
    Markov.unload(model)
    {:ok, model} = Markov.load("test", "model_reconfig")
    {:ok, config} = Markov.get_config(model)
    assert config[:partition_size] == 7500
    Markov.unload(model)
  end

  test "invalid configuration" do
    File.rm_rf(Path.join("test", "model_reconfig"))
    {:ok, model} = Markov.load("test", "model_reconfig")
    assert Markov.configure(model, sanitize_tokens: true) == {:error, :cant_change_sanitation}
    assert Markov.configure(model, order: 3) == {:error, :cant_change_order}
    Markov.unload(model)
  end

  test "training" do
    File.rm_rf("./test/model_training_singlepart")
    {:ok, model} = Markov.load("test", "model_training_singlepart")
    assert Markov.train(model, "hello world") == {:ok, :done}
    assert Markov.train(model, "hello world 2") == {:ok, :done}
    tokens = Markov.dump_partition(model, 0) |> MapSet.new
    reference = MapSet.new([
      {[:start, :start], %{"hello" => 2}},
      {[:start, "hello"], %{"world" => 2}},
      {["hello", "world"], %{:end => 1, "2" => 1}},
      {["world", "2"], %{end: 1}},
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "training with token sanitation" do
    File.rm_rf("./test/model_training_singlepart")
    {:ok, model} = Markov.load("test", "model_training_singlepart", sanitize_tokens: true)
    assert Markov.train(model, "hello world") == {:ok, :done}
    assert Markov.train(model, "hello, World") == {:ok, :done}
    tokens = Markov.dump_partition(model, 0) |> MapSet.new
    reference = MapSet.new([
      {[:start, :start], %{"hello" => 1, "hello," => 1}},
      {[:start, "hello"], %{"world" => 1, "World" => 1}},
      {["hello", "world"], %{:end => 2}},
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "training 5th order chain" do
    File.rm_rf("./test/model_training_singlepart")
    {:ok, model} = Markov.load("test", "model_training_singlepart", order: 5)
    assert Markov.train(model, "a b c d e") == {:ok, :done}
    assert Markov.train(model, "a b c d") == {:ok, :done}
    tokens = Markov.dump_partition(model, 0) |> MapSet.new
    reference = MapSet.new([
      {[:start, :start, :start, :start, :start], %{"a" => 2}},
      {[:start, :start, :start, :start, "a"], %{"b" => 2}},
      {[:start, :start, :start, "a", "b"], %{"c" => 2}},
      {[:start, :start, "a", "b", "c"], %{"d" => 2}},
      {[:start, "a", "b", "c", "d"], %{"e" => 1, :end => 1}},
      {["a", "b", "c", "d", "e"], %{end: 1}},
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end
end
