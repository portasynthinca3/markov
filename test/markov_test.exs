defmodule MarkovTest do
  use ExUnit.Case
  doctest Markov

  test "single-shot training" do
    assert Markov.train(%Markov{}, "hello, world!") == %Markov{
      links: %{
        [:start, :start] => %{"hello," => 1},
        [:start, "hello,"] => %{"world!" => 1},
        ["hello,", "world!"] => %{end: 1},
        :end => %{}
      }
    }
  end

  test "link weight increment" do
    assert Markov.train(%Markov{}, "hello, world!")
        |> Markov.train("hello, world!") == %Markov{
      links: %{
        [:start, :start] => %{"hello," => 2},
        [:start, "hello,"] => %{"world!" => 2},
        ["hello,", "world!"] => %{end: 2},
        :end => %{}
      }
    }
  end

  test "link creation" do
    assert Markov.train(%Markov{}, "hello, world!")
        |> Markov.train("hello, World!") == %Markov{
      links: %{
        :end => %{},
        [:start, :start] => %{"hello," => 2},
        [:start, "hello,"] => %{"World!" => 1, "world!" => 1},
        ["hello,", "World!"] => %{end: 1},
        ["hello,", "world!"] => %{end: 1}
      }
    }
  end

  test "next state: start" do
    assert Markov.train(%Markov{}, "hello, world!") |> Markov.next_state([:start, :start])
      == "hello,"
  end

  test "next state: middle" do
    assert Markov.train(%Markov{}, "hello, world!") |> Markov.next_state([:start, "hello,"])
      == "world!"
  end

  test "text generation" do
    assert Markov.train(%Markov{}, "hello, world!") |> Markov.generate_text() == "hello, world!"
  end

  test "probability test" do
    chain = Markov.train(%Markov{}, "hello, world!") |> Markov.train("hello, Elixir!")

    # count the number of times "world" and "Elixir" come up in 1000 rounds
    {world_cnt, elixir_cnt} = Enum.reduce(1..1000, {0, 0}, fn _, {w, e} ->
      case Markov.generate_text(chain) do
        "hello, world!" -> {w + 1, e}
        "hello, Elixir!" -> {w, e + 1}
        _ -> assert false
      end
    end)

    # assert max. deviation of 5%
    total = world_cnt + elixir_cnt
    assert abs(world_cnt - elixir_cnt) <= (total * 0.05)
  end

  test "probability test - custom tokens" do
    chain = Markov.train(%Markov{}, [:a, :b]) |> Markov.train([:a, :c])

    # count the number of times :a and :b come up in 1000 rounds
    {a_cnt, b_cnt} = Enum.reduce(1..1000, {0, 0}, fn _, {a, b} ->
      case Markov.generate_tokens(chain) do
        [:a, :b] -> {a + 1, b}
        [:a, :c] -> {a, b + 1}
        _ -> assert false
      end
    end)

    # assert max. deviation of 5%
    total = a_cnt + b_cnt
    assert abs(a_cnt - b_cnt) <= (total * 0.05)
  end
end
