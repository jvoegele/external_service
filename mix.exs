defmodule ExternalService.Mixfile do
  use Mix.Project

  @version "3.2.2"
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
        plt_core_path: "priv/plts",
        # `ExternalService.Test` calls into ExUnit from `lib/`, the way
        # `Phoenix.ConnTest` and `Bond.Test` do. ExUnit ships with Elixir, so
        # this adds it to the PLT rather than adding a dependency.
        plt_add_apps: [:ex_unit]
      ],

      # Hex
      description:
        "Elixir library for safely using any external service or API using automatic retry, circuit breakers, rate limiting, and a concurrency limit. Calls to external services can be synchronous, asynchronous background tasks, or multiple calls can be made in parallel for MapReduce style processing.",
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
      {:decorator, "~> 1.4", optional: true},
      {:errata, "~> 1.8"},
      {:flow, "~> 1.2", optional: true},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      # Only used to verify the ExternalService.RateLimiter.Hammer adapter against
      # the real library; the adapter itself calls `hit/3` on a module you supply,
      # so Hammer is not a dependency of this library at runtime.
      {:hammer, "~> 7.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Property-based tests only, and only for sequences — orderings of events over
      # time, which the exhaustive grids elsewhere in the suite cannot enumerate.
      # `only: [:dev, :test]` rather than `optional: true`: this library does not
      # ship generators, so nothing downstream ever needs it.
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: :external_service,
      # `guides` is included because the README links into it: hex.pm renders the
      # README out of this tarball, so without the guides those links 404 on the
      # package page. (HexDocs is unaffected — ExDoc rewrites them at build time.)
      files: [
        "lib",
        "guides",
        # Agent-facing guidance, consumed by `usage_rules`
        # (https://hex.pm/packages/usage_rules). Must be listed here or it is absent from
        # the tarball and `mix usage_rules.sync` finds nothing.
        "usage-rules.md",
        "mix.exs",
        # Shipped so `import_deps: [:external_service]` finds the
        # `locals_without_parens` rules for the paren-free `call fn -> ... end`
        # idiom the guides use; without it in the tarball the export block is
        # invisible to everyone installing from Hex.
        ".formatter.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md"
      ],
      maintainers: ["Jason Voegele"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "getting-started",
      extras: [
        "guides/getting-started.md",
        "guides/the-front-door.md",
        "guides/circuit-breakers.md",
        "guides/retries.md",
        "guides/rate-limiting.md",
        "guides/concurrency.md",
        "guides/tuning.md",
        "guides/error-handling.md",
        "guides/errata.md",
        "guides/telemetry.md",
        "guides/testing.md",
        "guides/distributed.md",
        "guides/flow.md",
        "guides/cheatsheet.cheatmd",
        "guides/migrating-to-2.0.md",
        "guides/migrating-to-3.0.md",
        "guides/about.md",
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/the-front-door.md",
          "guides/circuit-breakers.md",
          "guides/retries.md",
          "guides/rate-limiting.md",
          "guides/concurrency.md",
          "guides/tuning.md",
          "guides/error-handling.md",
          "guides/errata.md",
          "guides/telemetry.md",
          "guides/testing.md",
          "guides/distributed.md",
          "guides/flow.md"
        ],
        Reference: [
          "guides/cheatsheet.cheatmd",
          "guides/migrating-to-2.0.md",
          "guides/migrating-to-3.0.md",
          "guides/about.md"
        ]
      ],
      filter_modules: fn _module, meta ->
        # Tag modules with `@moduledoc internal: true` to exclude them from docs.
        not Map.get(meta, :internal, false)
      end
    ]
  end
end
