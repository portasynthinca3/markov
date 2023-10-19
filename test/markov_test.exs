defmodule MarkovTest do
  use ExUnit.Case

  setup do
    File.rm_rf("model_test")
    {:ok, model} = Markov.load("model_test")

    on_exit(:cleanup, fn ->
      :ok = Markov.unload(model)
      File.rm_rf("model_test")
    end)

    [model: model]
  end

  test "creating the model", _ctx do
    # done in setup
    assert true
  end

  test "reconfiguration", ctx do
    Markov.configure(ctx.model, shift_probabilities: true)
    config = Markov.get_config(ctx.model)
    assert config[:shift_probabilities] == true
  end

  test "configuration persistence", ctx do
    Markov.configure(ctx.model, shift_probabilities: true)
    Markov.unload(ctx.model)
    {:ok, model} = Markov.load("model_test")
    on_exit(:cleanup, fn -> :ok = Markov.unload(model) end)
    config = Markov.get_config(model)
    assert config[:shift_probabilities] == true
  end

  test "invalid configuration", ctx do
    assert Markov.configure(ctx.model, sanitize_tokens: true) == {:error, {:cant_change, :sanitize_tokens}}
    assert Markov.configure(ctx.model, order: 3) == {:error, {:cant_change, :order}}
  end

  test "empty model", ctx do
    assert Markov.generate_text(ctx.model) == {:error, {:no_connections, [:"$_start", :"$_start"]}}
  end

  test "data persistence", ctx do
    :ok = Markov.train(ctx.model, "hello world")
    Markov.unload(ctx.model)
    {:ok, model} = Markov.load("model_test")
    on_exit(:cleanup, fn -> :ok = Markov.unload(model) end)
    assert Markov.generate_text(model) == {:ok, "hello world"}
  end

  test "generation", ctx do
    assert Markov.train(ctx.model, "a b c d") == :ok
    assert Markov.generate_text(ctx.model) == {:ok, "a b c d"}
  end

  test "probability correctness", ctx do
    assert Markov.train(ctx.model, "1") == :ok
    assert Markov.train(ctx.model, "2") == :ok

    %{{:ok, "1"} => one, {:ok, "2"} => two} =
      0..499
      |> Enum.map(fn _ -> Markov.generate_text(ctx.model) end)
      |> Enum.frequencies
    assert one >= 225 and one <= 275
    assert two >= 225 and two <= 275
    assert one + two == 500
  end

  # test "log reading", ctx do
  #   assert Markov.train(ctx.model, "1") == :ok
  #   assert Markov.generate_text(ctx.model) == {:ok, "1"}
  #   assert Markov.read_log(ctx.model) |> Enum.map(fn x -> %{x | date_time: nil} end) == [
  #     %Markov.Operation{type: :start, date_time: nil, arg: nil},
  #     %Markov.Operation{type: :train, date_time: nil, arg: ["1"]},
  #   ]
  # end
end
