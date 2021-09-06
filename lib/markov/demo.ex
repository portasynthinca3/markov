defmodule Markov.Demo do
  def generate_shakespeare do
    data = File.read!("the_comedy_of_errors.txt")
    lines = String.split(data, "\n")
    chain = Enum.reduce(lines, %Markov{}, fn line, chain ->
      if String.trim(line) == "" do
        chain
      else
        Markov.train(chain, line)
      end
    end)

    for _ <- 1..100 do
      chain |> Markov.generate_text |> IO.puts
    end

    :ok
  end
end
