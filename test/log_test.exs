defmodule LogTestTest do
  use ExUnit.Case, async: true

  test "v4.x log reading" do
    assert Markov.Log.read_v4("test/v4_history.log") == [
      %Markov.Log.Operation{date_time: ~U[2023-10-19 01:47:53.103Z], type: :start, arg: nil},
      %Markov.Log.Operation{date_time: ~U[2023-10-19 01:48:02.768Z], type: :train, arg: ["hello", "world"]},
      %Markov.Log.Operation{date_time: ~U[2023-10-19 01:48:08.025Z], type: :gen, arg: {:ok, ["hello", "world"]}},
      %Markov.Log.Operation{date_time: ~U[2023-10-19 01:48:11.882Z], type: :end, arg: nil}
    ]
  end

  test "v4.x migration" do
    File.rm_rf("model_log")
    {:ok, model} = Markov.load("model_log")
    on_exit(fn ->
      Markov.unload(model)
      File.rm_rf("model_log")
    end)

    Markov.Log.migrate_from_v4("test/v4_history.log", model)
    assert Markov.generate_text(model) == {:ok, "hello world"}
  end
end
