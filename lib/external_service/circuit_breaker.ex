defmodule ExternalService.CircuitBreaker do
  @moduledoc """
  The behaviour implemented by circuit breaker backends.

  A service's breaker is chosen with the `:backend` circuit breaker option, and
  defaults to `ExternalService.CircuitBreaker.Fuse` — a node-local breaker built
  on the [`:fuse`](https://github.com/jlouis/fuse) library.

  ## Writing a backend

      defmodule MyApp.CircuitBreaker do
        @behaviour ExternalService.CircuitBreaker

        @impl true
        def install(service, options) do
          {:ok, %{key: service, tolerate: options[:tolerate]}}
        end

        @impl true
        def ask(_service, config), do: if MyStore.open?(config.key), do: :blown, else: :ok

        @impl true
        def melt(_service, config), do: MyStore.record_failure(config.key)

        @impl true
        def reset(_service, config), do: MyStore.close(config.key)

        @impl true
        def remove(_service, config), do: MyStore.forget(config.key)
      end

  Backends are **stateless modules**. `c:install/2` returns an opaque config term
  that is stored with the rest of the service state (in `:persistent_term`) and
  handed back to every other callback, so a backend needs no process, supervisor,
  or registry of its own.

  This library never calls these functions on your behalf outside a guarded call.
  The user-facing view of a breaker stays at the level of
  `ExternalService.available?/1`, `ExternalService.blown?/1`, and
  `ExternalService.reset/1` — the concept, not the individual operations.
  """

  @type service :: ExternalService.service()

  @typedoc "Backend-private state, produced by `c:install/2` and passed to every other callback."
  @type config :: term()

  @typedoc "An installed circuit breaker: the backend module paired with its config."
  @type t :: {module(), config()}

  @doc """
  Installs the circuit breaker for `service`.

  Receives the validated `:circuit_breaker` options with any backend-specific
  options merged in, and returns the backend's config term.
  """
  @callback install(service(), options :: keyword()) :: {:ok, config()}

  @doc """
  Reports whether the breaker will currently admit a call.

  A breaker that does not exist (for example because the service was stopped
  while a call was in flight) must be reported as `:blown` rather than raising.
  """
  @callback ask(service(), config()) :: :ok | :blown

  @doc "Records a single failure against the breaker."
  @callback melt(service(), config()) :: :ok

  @doc "Closes the breaker and discards its recorded failures."
  @callback reset(service(), config()) :: :ok | {:error, :not_found}

  @doc "Tears the breaker down. Must be safe to call more than once."
  @callback remove(service(), config()) :: :ok

  @default_backend ExternalService.CircuitBreaker.Fuse

  # The functions below dispatch to a backend on `ExternalService`'s behalf. They
  # are not part of the public API: only the behaviour above is public.

  @doc false
  @spec default_backend() :: module()
  def default_backend, do: @default_backend

  @doc false
  @spec install(service(), keyword()) :: t()
  def install(service, options) do
    {module, options} = split_backend(options)
    {:ok, config} = module.install(service, options)
    {module, config}
  end

  @doc false
  @spec ask(service(), t()) :: :ok | :blown
  def ask(service, {module, config}), do: module.ask(service, config)

  @doc false
  @spec melt(service(), t()) :: :ok
  def melt(service, {module, config}), do: module.melt(service, config)

  @doc false
  @spec reset(service(), t()) :: :ok | {:error, :not_found}
  def reset(service, {module, config}), do: module.reset(service, config)

  @doc false
  @spec remove(service(), t()) :: :ok
  def remove(service, {module, config}), do: module.remove(service, config)

  # `:backend` accepts either a bare module or a `{module, options}` tuple. The
  # backend-specific options are merged over the shared circuit-breaker options so
  # that a backend receives everything it needs in a single keyword list.
  defp split_backend(options) do
    case Keyword.pop(options, :backend, @default_backend) do
      {{module, backend_options}, options} -> {module, Keyword.merge(options, backend_options)}
      {module, options} -> {module, options}
    end
  end
end
