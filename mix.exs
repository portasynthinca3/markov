defmodule Markov.MixProject do
  use Mix.Project

  def project do
    [
      app: :markov,
      version: "0.1.0",
      elixir: "~> 1.12",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      description: description(),
      deps: deps(),
      package: package()
    ]
  end

  defp description do
    """
    Markov-chain-based text generation library
    """
  end

  defp deps do
    [{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}]
  end

  defp package do
    [
      name: :markov,
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["portasynthinca3"],
      licenses: ["WTFPL"],
      links: %{"GitHub" => "https://github.com/portasynthinca3/markov"}
    ]
  end
end
