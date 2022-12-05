defmodule MarkovTest do
  use ExUnit.Case

  test "creating the model" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")
    :ok = Markov.unload(model)
  end

  test "reconfiguration" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")
    Markov.configure(model, shift_probabilities: true)
    {:ok, config} = Markov.get_config(model)
    Markov.unload(model)
    assert config[:shift_probabilities] == true
  end

  test "configuration persistence" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")
    Markov.configure(model, partition_size: 7500)
    Markov.unload(model)
    {:ok, model} = Markov.load("model")
    {:ok, config} = Markov.get_config(model)
    assert config[:partition_size] == 7500
    Markov.unload(model)
  end

  test "invalid configuration" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")
    assert Markov.configure(model, sanitize_tokens: true) == {:error, :cant_change_sanitation}
    assert Markov.configure(model, order: 3) == {:error, :cant_change_order}
    Markov.unload(model)
  end

  test "training" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")
    assert Markov.train(model, "hello world") == :ok
    assert Markov.train(model, "hello world 2") == :ok
    tokens = Markov.dump_model(model) |> MapSet.new
    reference = MapSet.new([
      %Markov.Database.Link{mod_from: {"model", [:start, :start]},   tag: :"$none", to: "hello", occurrences: 2},
      %Markov.Database.Link{mod_from: {"model", [:start, "hello"]},  tag: :"$none", to: "world", occurrences: 2},
      %Markov.Database.Link{mod_from: {"model", ["hello", "world"]}, tag: :"$none", to: :end,    occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", ["hello", "world"]}, tag: :"$none", to: "2",     occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", ["world", "2"]},     tag: :"$none", to: :end,    occurrences: 1},
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "training with token sanitation" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model", sanitize_tokens: true)
    assert Markov.train(model, "hello world") == :ok
    assert Markov.train(model, "hello, World") == :ok
    tokens = Markov.dump_model(model) |> MapSet.new
    reference = MapSet.new([
      %Markov.Database.Link{mod_from: {"model", [:start, :start]},   tag: :"$none", to: "hello",  occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", [:start, :start]},   tag: :"$none", to: "hello,", occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", [:start, "hello"]},  tag: :"$none", to: "World",  occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", [:start, "hello"]},  tag: :"$none", to: "world",  occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", ["hello", "world"]}, tag: :"$none", to: :end,     occurrences: 2}
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "training 5th order chain" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model", order: 5)
    assert Markov.train(model, "a b c d e") == :ok
    assert Markov.train(model, "a b c d") == :ok
    tokens = Markov.dump_model(model) |> MapSet.new
    reference = MapSet.new([
      %Markov.Database.Link{mod_from: {"model", [:start, :start, :start, :start, :start]}, tag: :"$none", to: "a", occurrences: 2},
      %Markov.Database.Link{mod_from: {"model", [:start, :start, :start, :start, "a"]}, tag: :"$none", to: "b", occurrences: 2},
      %Markov.Database.Link{mod_from: {"model", [:start, :start, :start, "a", "b"]}, tag: :"$none", to: "c", occurrences: 2},
      %Markov.Database.Link{mod_from: {"model", [:start, :start, "a", "b", "c"]}, tag: :"$none", to: "d", occurrences: 2},
      %Markov.Database.Link{mod_from: {"model", [:start, "a", "b", "c", "d"]}, tag: :"$none", to: :end, occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", [:start, "a", "b", "c", "d"]}, tag: :"$none", to: "e", occurrences: 1},
      %Markov.Database.Link{mod_from: {"model", ["a", "b", "c", "d", "e"]}, tag: :"$none", to: :end, occurrences: 1},
    ])
    assert MapSet.equal?(tokens, reference)
    Markov.unload(model)
  end

  test "generation" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")
    assert Markov.train(model, "a b c d") == :ok
    assert Markov.generate_text(model) == {:ok, "a b c d"}
    Markov.unload(model)
  end

  test "probability correctness" do
    Markov.nuke("model")
    {:ok, model} = Markov.load("model")

    assert Markov.train(model, "1") == :ok
    assert Markov.train(model, "2") == :ok

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
    Markov.nuke("model")
    {:ok, model} = Markov.load("model", store_log: [:start, :train])

    assert Markov.train(model, "1") == :ok
    assert Markov.generate_text(model) == {:ok, "1"}
    assert Markov.read_log(model) |> Enum.map(fn x -> %{x | date_time: nil} end) == [
      %Markov.Operation{type: :start, date_time: nil, arg: nil},
      %Markov.Operation{type: :train, date_time: nil, arg: ["1"]},
    ]

    Markov.unload(model)
  end
end
