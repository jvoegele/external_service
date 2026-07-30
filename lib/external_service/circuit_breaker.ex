defmodule ExternalService.CircuitBreaker do
  @moduledoc false

  # The circuit breaker seam.
  #
  # `ExternalService` never talks to a circuit-breaker implementation directly;
  # every operation goes through this module, which dispatches to the backend
  # configured for the service. The default backend,
  # `ExternalService.CircuitBreaker.Fuse`, wraps the `:fuse` library and preserves
  # the behavior of every previous release.
  #
  # Backends are *stateless modules*: `install/2` returns an opaque config term
  # that is stored alongside the rest of the service state (in `:persistent_term`)
  # and handed back to every other callback. A backend therefore needs no process,
  # no supervision tree, and no registry of its own — which is what lets a
  # cluster-aware backend be a drop-in replacement.

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

  @doc "The backend used when no `:backend` option is given."
  @spec default_backend() :: module()
  def default_backend, do: @default_backend

  @spec install(service(), keyword()) :: t()
  def install(service, options) do
    {module, options} = split_backend(options)
    {:ok, config} = module.install(service, options)
    {module, config}
  end

  @spec ask(service(), t()) :: :ok | :blown
  def ask(service, {module, config}), do: module.ask(service, config)

  @spec melt(service(), t()) :: :ok
  def melt(service, {module, config}), do: module.melt(service, config)

  @spec reset(service(), t()) :: :ok | {:error, :not_found}
  def reset(service, {module, config}), do: module.reset(service, config)

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
