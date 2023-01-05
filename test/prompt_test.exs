defmodule PromptTest do
  use ExUnit.Case
  import Markov.Prompt

  test "prompts" do
    File.rm_rf("model_test")
    {:ok, model} = Markov.load("model_test", store_log: [])

    train_on_list(model, [
      "tell me a joke",
      "why did the chicken cross the road? to get to the other side.",
      "tell me a science fact",
      "uranus is very big"
    ])

    %{{:ok, "why did the chicken cross the road? to get to the other side."} => jokes} =
      0..999
        |> Enum.map(fn _ -> generate_prompted(model, "i wanna hear a joke") end)
        |> Enum.frequencies
    assert jokes >= 650

    %{{:ok, "uranus is very big"} => facts} =
      0..999
        |> Enum.map(fn _ -> generate_prompted(model, "SCIENCE FACT. NOW!!") end)
        |> Enum.frequencies
    assert facts >= 650

    Markov.unload(model)
  end
end
