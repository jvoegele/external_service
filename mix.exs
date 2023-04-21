defmodule ExternalService.Mixfile do
  use Mix.Project

  def project do
    [
      app: :external_service,
      version: "1.1.2",
      description:
        "Elixir library for safely using any external service or API using automatic retry with rate limiting and circuit breakers. Calls to external services can be synchronous, asynchronous background tasks, or multiple calls can be made in parallel for MapReduce style processing.",
      source_url: "https://github.com/jvoegele/external_service",
      elixir: "~> 1.4",
      start_permanent: Mix.env() == :prod,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      # mod: {ExternalService.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fuse, "~> 2.5"},
      {:retry, "~> 0.18.0"},
      {:ex_rated, "~> 2.1"},
      {:deep_merge, "~> 1.0"},
      {:ex_doc, "~> 0.29.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    # These are the default files included in the package
    [
      name: :external_service,
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Jason Voegele"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/jvoegele/external_service"}
    ]
  end

  defp docs do
    [
      extras: ["README.md"],
      main: "readme"
    ]
  end
end
