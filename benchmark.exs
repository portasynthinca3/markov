File.rm_rf("model_bench")
{:ok, model} = Markov.load("model_bench")
Markov.train(model, "a")

Benchee.run(
  %{
    "train 1 token" =>   fn -> Markov.train(model, "a") end,
    "train 5 tokens" =>  fn -> Markov.train(model, "a b c d e") end,
    "train 10 tokens" => fn -> Markov.train(model, "a b c d e f g h i j") end,
    "train 20 tokens" => fn -> Markov.train(model, "a b c d e f g h i j k l m n o p q r s t") end,
    "generate" =>        fn -> Markov.generate_text(model) end,

    "train with prompt" => fn -> Markov.Prompt.train(model, "example joke", "tell me a joke") end,
    "generate prompted" => fn -> Markov.Prompt.generate_prompted(model, "i need a joke") end
  },
  time: 5,
  memory_time: 2
)

# [{pid, _}] = Registry.lookup(Markov.ModelServers, "model_bench")
# :fprof.start
# :fprof.trace([:start, procs: [pid]])
# 1..50 |> Enum.map(fn _ -> Markov.train(model, "a b c d e f g h i j k l m n o p q r s t") end)
# :fprof.trace(:stop)
# :fprof.profile
