defmodule Markov.MixProject do
  use Mix.Project

  def project do
    [
      app: :markov,
      version: "2.0.0",
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
    Text generation library based on second-order Markov chains
    """
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:flow, ">= 1.2.0"},
      {:nx, "~> 0.3"},
      {:exla, "~> 0.3"},
      {:ex_hash_ring, "~> 6.0"}
    ]
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
