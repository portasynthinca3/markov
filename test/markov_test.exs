defmodule MarkovTest do
  use ExUnit.Case

  test "creating the model" do
    File.rm_rf(Path.join("test", "model"))
    {:ok, model} = Markov.load("test", "model")
    Markov.unload(model)
  end

  test "creating the model in a non-existent dir" do
    assert Markov.load("/hopefully/this/path/doesnt", "exist") == {:error, :enoent}
  end

  test "reconfiguration" do
    {:ok, model} = Markov.load("test", "model")
    Markov.configure(model, partition_size: 5000)
    {:ok, config} = Markov.get_config(model)
    Markov.unload(model)
    assert config[:partition_size] == 5000
  end

  test "configuration persistence" do
    {:ok, model} = Markov.load("test", "model")
    Markov.configure(model, partition_size: 7500)
    Markov.unload(model)
    {:ok, model} = Markov.load("test", "model")
    {:ok, config} = Markov.get_config(model)
    assert config[:partition_size] == 7500
    Markov.unload(model)
  end

  test "invalid configuration" do
    File.rm_rf(Path.join("test", "model"))
    {:ok, model} = Markov.load("test", "model")
    assert Markov.configure(model, sanitize_tokens: true) == {:error, :cant_change_sanitation}
    assert Markov.configure(model, order: 3) == {:error, :cant_change_order}
    Markov.unload(model)
  end

  test "training" do
    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model")
    assert Markov.train(model, "hello world") == {:ok, :done}
    assert Markov.train(model, "hello world 2") == {:ok, :done}
    tokens = Markov.dump_partition(model, 0) |> MapSet.new
    reference = MapSet.new([
      {[:start, :start], :"$none", "hello", 2},
      {[:start, "hello"], :"$none", "world", 2},
      {["hello", "world"], :"$none", :end, 1},
      {["hello", "world"], :"$none", "2", 1},
      {["world", "2"], :"$none", :end, 1}
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "training with token sanitation" do
    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model", sanitize_tokens: true)
    assert Markov.train(model, "hello world") == {:ok, :done}
    assert Markov.train(model, "hello, World") == {:ok, :done}
    tokens = Markov.dump_partition(model, 0) |> MapSet.new
    reference = MapSet.new([
      {[:start, :start], :"$none", "hello", 1},
      {[:start, :start], :"$none", "hello,", 1},
      {[:start, "hello"], :"$none", "World", 1},
      {[:start, "hello"], :"$none", "world", 1},
      {["hello", "world"], :"$none", :end, 2}
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "training 5th order chain" do
    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model", order: 5)
    assert Markov.train(model, "a b c d e") == {:ok, :done}
    assert Markov.train(model, "a b c d") == {:ok, :done}
    tokens = Markov.dump_partition(model, 0) |> MapSet.new
    reference = MapSet.new([
      {[:start, :start, :start, :start, :start], :"$none", "a", 2},
      {[:start, :start, :start, :start, "a"], :"$none", "b", 2},
      {[:start, :start, :start, "a", "b"], :"$none", "c", 2},
      {[:start, :start, "a", "b", "c"], :"$none", "d", 2},
      {[:start, "a", "b", "c", "d"], :"$none", :end, 1},
      {[:start, "a", "b", "c", "d"], :"$none", "e", 1},
      {["a", "b", "c", "d", "e"], :"$none", :end, 1}
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "generation" do
    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model")
    assert Markov.train(model, "a b c d") == {:ok, :done}
    assert Markov.generate_text(model) == {:ok, "a b c d"}
    Markov.unload(model)
  end

  test "probability correctness" do
    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model")

    assert Markov.train(model, "1") == {:ok, :done}
    assert Markov.train(model, "2") == {:ok, :done}

    %{{:ok, "1"} => one, {:ok, "2"} => two} =
      0..499
      |> Enum.map(fn _ -> Markov.generate_text(model) end)
      |> Enum.frequencies
    assert one >= 225 and one <= 275
    assert two >= 225 and two <= 275
    assert one + two == 500

    Markov.unload(model)
  end

  test "log reading" do
    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model")

    assert Markov.train(model, "1") == {:ok, :done}
    assert Markov.generate_text(model) == {:ok, "1"}
    matches = case Markov.read_log(model) do
      {:ok, [
        {_, :start, nil},
        {_, :train, ["1"]},
        {_, :gen, {:ok, ["1"]}},
      ]} -> true
      _ -> false
    end
    assert matches

    Markov.unload(model)
  end

  test "repartition integrity" do
    training_data = [
      "asd sdf dfg fgh ghj hjk jkl kl",
      "a s d f g h j k l",
      "as sd df fg gh hj jk kl",
      "qwe wer ert rty tyu yui uio iop",
      "q w e r t y u i o p",
      "qw we er rt ty yu ui io op"
    ]

    File.rm_rf("./test/model")
    {:ok, model} = Markov.load("test", "model", partition_size: 10)

    for str <- training_data, do:
      assert Markov.train(model, str) == {:ok, :done}
    for _ <- 0..499, do:
      assert :erlang.element(2, Markov.generate_text(model)) in training_data

    Markov.unload(model)
  end
end
