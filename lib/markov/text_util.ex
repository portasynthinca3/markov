defmodule Markov.TextUtil do
  def sanitize_token(tok) when not is_binary(tok) do tok end
  def sanitize_token(tok) do
    tok |> String.trim
        |> String.replace(~r/(^[^\w]+)|([^\w]+$)/m, "") # trim non-word characters
        |> String.downcase
  end
end
