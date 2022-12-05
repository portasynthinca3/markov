defmodule Markov.Prompt do
  @moduledoc """
  Thin wrapper around `Markov` to make the chain respond to prompts assuming
  it's been trained on the appropriate data
  """

  defp map_token(token) do
    token = Markov.TextUtil.sanitize_token(token)
    type_to_score = %{noun: 50, verb: 30, adj: 25, adv: 10}
    result = :ets.lookup(Markov.Dictionary, token)

    case result do
      [] -> []
      [{_, :prep}] -> []
      [{_, type}] -> [{token, Map.get(type_to_score, type)}]
    end
  end

  defp generate_tags(text), do:
    String.split(text) |> Enum.flat_map(&map_token/1)

  @doc """
  Assuming your application receives a stream of strings, call this function
  instead of `Markov.train/3` with the current and last string
  """
  @spec train(model :: Markov.model_reference(), new_text :: String.t(),
    last_text :: String.t() | nil, tags :: [any()])
    :: {:ok, :done | :deferred} | {:error, term()}
  def train(model, new_text, last_text \\ nil, tags \\ []) do
    tags = if last_text do
      generate_tags(last_text) |> Enum.map(fn {token, _score} -> token end)
    else [] end ++ tags

    Markov.train(model, new_text, tags)
  end

  @doc """
  Trains the model on a list of consecutive strings
  """
  @spec train_on_list(model :: Markov.model_reference(), list :: [String.t()]) :: :ok
  def train_on_list(model, list) do
    case list do
      [first | _] ->
        train(model, first)

        _ = Enum.reduce(list, fn string, last_string ->
          train(model, string, last_string)
          string # new "last string"
        end)
        :ok

      _ -> :ok
    end
  end

  @doc """
  Generates the text from a prompt
  """
  @spec generate_prompted(model :: Markov.model_reference(), prompt :: String.t(),
    query :: Markov.tag_query()) :: {:ok, String.t()} | {:error, term()}
  def generate_prompted(model, prompt, tag_query \\ true) do
    tags = generate_tags(prompt)
    Markov.generate_text(model, {tag_query, :score, tags})
  end
end
