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
    {:ok, model} = Markov.load("test", "model_reconfig", sanitize_tokens: true)
    assert Markov.configure(model, sanitize_tokens: false) == {:error, :cant_disable_sanitation}
    Markov.unload(model)
  end
end
