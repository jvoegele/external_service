defmodule ExternalService.Mixfile do
  use Mix.Project

  @version "2.0.0-dev"
  @source_url "https://github.com/jvoegele/external_service"

  def project do
    [
      app: :external_service,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Dialyzer: keep PLTs in a stable, cacheable location for CI
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],

      # Hex
      description:
        "Elixir library for safely using any external service or API using automatic retry with rate limiting and circuit breakers. Calls to external services can be synchronous, asynchronous background tasks, or multiple calls can be made in parallel for MapReduce style processing.",
      package: package(),

      # Docs
      name: "ExternalService",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fuse, "~> 2.5"},
      {:retry, "~> 0.18"},
      {:ex_rated, "~> 2.1"},
      {:deep_merge, "~> 1.0"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: :external_service,
      files: ["lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md"],
      maintainers: ["Jason Voegele"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      filter_modules: fn _module, meta ->
        # Tag modules with `@moduledoc internal: true` to exclude them from docs.
        not Map.get(meta, :internal, false)
      end
    ]
  end
end
