defmodule ExternalService.Mixfile do
  use Mix.Project

  def project do
    [
      app: :external_service,
      version: "0.5.0",
      elixir: "~> 1.5",
      start_permanent: Mix.env == :prod,
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
      {:retry, "~> 0.7.0"},
    ]
  end
end
