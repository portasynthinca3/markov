defmodule Markov.ListUtil do
  @doc """
  Splits the list into sequential three-tuples

  ## Example
      iex> Markov.ListUtil.ttuples([1, 2, 3, 4, 5, 6])
      [{1, 2, 3}, {2, 3, 4}, {3, 4, 5}, {4, 5, 6}]
  """
  @spec ttuples(list()) :: list()
  def ttuples(list) do
    Enum.zip([
      list |> Enum.slice(0..-3),
      list |> Enum.slice(1..-2),
      list |> Enum.slice(2..-1)
    ])
  end
end
