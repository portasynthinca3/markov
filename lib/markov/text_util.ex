defmodule Markov.TextUtil do
  @doc """
  Strips textual tokens of preceding and trailing non-word characters, as well
  as downcases them

      iex> Markov.TextUtil.sanitize_token(:atom)
      :atom

      iex> Markov.TextUtil.sanitize_token("test")
      "test"

      iex> Markov.TextUtil.sanitize_token("  !!!???///    tEsT     >>>")
      "test"
  """
  def sanitize_token(tok) when not is_binary(tok) do tok end
  def sanitize_token(tok) do
    tok |> String.trim
        |> String.replace(~r/(^[^\w]+)|([^\w]+$)/m, "") # trim non-word characters
        |> String.downcase
  end
end
