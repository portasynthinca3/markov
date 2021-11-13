defmodule UtilTest do
  use ExUnit.Case
  doctest Markov.ListUtil
  doctest Markov.TextUtil

  test "ListUtil.ttuples" do
    assert Markov.ListUtil.ttuples([1, 2, 3, 4, 5, 6]) == [{1, 2, 3}, {2, 3, 4}, {3, 4, 5}, {4, 5, 6}]
  end

  test "TextUtil.sanitize_token" do
    assert Markov.TextUtil.sanitize_token(:atom) == :atom
    assert Markov.TextUtil.sanitize_token("pure") == "pure"
    assert Markov.TextUtil.sanitize_token("!,.,.    OOga bOOGa         .///??!!!") == "ooga booga"
  end
end
