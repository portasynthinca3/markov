defmodule Markov.ListUtil do
  @doc """
  Splits the list into `size`-sized lists of consecutive elements

  ## Example

      iex> Markov.ListUtil.overlapping_stride([:a, :b, :c, :d, :e, :f, :g], 3)
      [[:a, :b, :c], [:b, :c, :d], [:c, :d, :e], [:d, :e, :f], [:e, :f, :g]]

      iex> Markov.ListUtil.overlapping_stride([:a, :b, :c, :d, :e, :f, :g], 2)
      [[:a, :b], [:b, :c], [:c, :d], [:d, :e], [:e, :f], [:f, :g]]
  """
  @spec overlapping_stride(list(), non_neg_integer()) :: list()
  def overlapping_stride(list, size) do
    for i <- 0..(length(list) - size) do
      for j <- 0..(size - 1), do: Enum.at(list, i + j)
    end
  end
end
