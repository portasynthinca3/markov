File.rm_rf("model_bench")
{:ok, model} = Markov.load("model_bench")

Benchee.run(
  %{
    "train 1 token" =>   fn -> Markov.train(model, "a") end,
    "train 5 tokens" =>  fn -> Markov.train(model, "a b c d e") end,
    "train 10 tokens" => fn -> Markov.train(model, "a b c d e f g h i j") end,
    "train 20 tokens" => fn -> Markov.train(model, "a b c d e f g h i j k l m n o p q r s t") end,
    "train prompted" =>  fn -> Markov.Prompt.train(model, "example joke", "tell me a joke") end
  },
  time: 2,
  memory_time: 0,
  warmup: 0.1
)

Benchee.run(
  %{
    "generate" =>          fn -> Markov.generate_text(model) end,
    "generate prompted" => fn -> Markov.Prompt.generate_prompted(model, "i need a joke") end
  },
  time: 2,
  memory_time: 0,
  warmup: 0.1
)

parent = self()
pid = spawn(fn ->
  receive do
    :start -> :ok
  end
  1..100 |> Enum.map(fn _ -> Markov.train(model, "a b c d e f g h i j k l m n o p q r s t") end)
  send(parent, :done)
end)
:fprof.start
:fprof.trace([:start, procs: [pid]])
send(pid, :start)
receive do
  :done -> :ok
end
:fprof.trace(:stop)
:fprof.profile

:ok = Markov.unload(model)
File.rm_rf("model_bench")
