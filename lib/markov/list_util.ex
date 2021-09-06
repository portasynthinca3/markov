defmodule Markov.ListUtil do
  @doc """
  Splits the list into sequential three-tuples

  ## Example
      iex> Markov.ListUtil.ttuples([1, 2, 3, 4, 5, 6])
      [{1, 2, 3}, {2, 3, 4}, {3, 4, 5}, {4, 5, 6}]
  """
  @spec ttuples(list()) :: list()
  def ttuples(list) do
    first_elements = list |> Enum.reverse |> tl() |> tl() |> Enum.reverse
    second_elements = list |> tl() |> Enum.reverse |> tl() |> Enum.reverse
    third_elements = list |> tl() |> tl()
    Enum.zip([first_elements, second_elements, third_elements])
  end
end
