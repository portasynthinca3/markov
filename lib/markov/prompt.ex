defmodule Markov.Prompt do
  @moduledoc """
  Thin wrapper around `Markov` to make the chain respond to prompts assuming
  it's been trained on the appropriate data
  """

  defp map_token({token, index}, {lower_thres, upper_thres}) do
    token = Markov.TextUtil.sanitize_token(token)
    type_to_score = %{noun: 50, verb: 30, adj: 25, adv: 10, prep: 5}
    result = :ets.lookup(Markov.Dictionary, token)

    score = case result do
      [] -> 1
      [{_, type}] -> Map.get(type_to_score, type)
    end

    [
      {token, score},
      case index do
        i when i <= lower_thres -> {{token, :start}, 2}
        i when i >= upper_thres -> {{token, :end}, 2}
        _ -> {{token, :middle}, 2}
      end
    ]
  end

  defp generate_tags(text) do
    tokens = String.split(text)
    max = length(tokens) - 1
    range = 0..max

    thres = {floor(0.2 * max), ceil(0.8 * max)}

    Enum.zip(tokens, range)
      |> Enum.flat_map(fn item -> map_token(item, thres) end)
      |> IO.inspect
  end

  @doc """
  Assuming your application receives a stream of strings, call this function
  instead of `Markov.train/3` with the current and last string
  """
  @spec train(model :: Markov.model_reference(), new_text :: String.t(), last_text :: String.t() | nil)
    :: {:ok, :done | :deferred} | {:error, term()}
  def train(model, new_text, last_text \\ nil) do
    if last_text do
      tags = generate_tags(last_text)
        |> Enum.map(fn {token, _score} -> token end)
      Markov.train(model, new_text, tags)
    else
      Markov.train(model, new_text)
    end
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
  @spec generate_prompted(model :: Markov.model_reference(), prompt :: String.t()) ::
    {:ok, String.t()} | {:error, term()}
  def generate_prompted(model, prompt) do
    tags = generate_tags(prompt)
    Markov.generate_text(model, {true, :score, tags})
  end
end
