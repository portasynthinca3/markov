defmodule Markov.MixProject do
  use Mix.Project

  def project do
    [
      app: :markov,
      version: "3.0.6",
      elixir: "~> 1.12",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      description: description(),
      deps: deps(),
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md"],
        logo: "logo/logo.png",
        assets: "doc_assets"
      ],
      test_coverage: [ignore_modules: [
        Markov.ModelServer.State,
        Markov.Sup,
        Markov.PartTimeout
      ]],
      aliases: ["test.ci": ["test --color --max-cases 10"]]
    ]
  end

  def application do
    [
      extra_applications: [],
      mod: {Markov.App, []}
    ]
  end

  defp description do
    """
    High-performance text generation library based on nth-order Markov chains
    """
  end

  defp deps do
    [
      {:flow, "~> 1.2"},
      {:nx, "~> 0.3"},
      {:exla, "~> 0.3"},
      {:amnesia, "~> 0.2.8"},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:observer_cli, "~> 1.7", only: :dev, runtime: false},
      {:credo, "~> 1.6", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :markov,
      files: ["lib", "mix.exs", "README*", "LICENSE*", "priv/*"],
      maintainers: ["portasynthinca3"],
      licenses: ["WTFPL"],
      links: %{"GitHub" => "https://github.com/portasynthinca3/markov"}
    ]
  end
end
