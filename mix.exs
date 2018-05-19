defmodule ExternalService.Mixfile do
  use Mix.Project

  def project do
    [
      app: :external_service,
      version: "0.8.5",
      description:
        "Elixir library for safely using external services using retry logic, circuit breakers, and automatic rate limiting",
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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fuse, "~> 2.4"},
      # {:retry, "~> 0.8"},
      {:retry, github: "jvoegele/ElixirRetry", branch: "feature/rescue_only_runtime_list"},
      {:ex_rated, "~> 1.3"},
      {:ex_doc, "~> 0.18", only: :dev, runtime: false},
      {:dialyxir, "~> 0.5", only: [:dev, :test], runtime: false},
      {:credo, "~> 0.9.2", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    # These are the default files included in the package
    [
      name: :external_service,
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Jason Voegele", "Chad Jablonski"],
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
