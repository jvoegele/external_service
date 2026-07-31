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

  ## Driving a breaker directly

  Most of the time the breaker is driven for you: `ExternalService.call/3` asks
  it before each attempt and melts it on failure. The functions in this module
  are for the cases that fall outside a guarded call.

  The one that matters is `melt/1` — recording a failure the library never saw:

      # A streaming connection to the service dropped, or a webhook timed out.
      # That is a real failure, but it did not happen inside `call/3`.
      ExternalService.CircuitBreaker.melt(:payments)

  Melting counts toward the service's configured `:tolerate` exactly as an
  in-call failure does, so enough out-of-band failures will open the breaker —
  and, with `ExternalService.CircuitBreaker.Cluster`, open it across the cluster.

  `ask/1` and `reset/1` are also here, though `ExternalService.available?/1`,
  `ExternalService.blown?/1`, and `ExternalService.reset/1` say the same thing
  more readably and are usually the better call.
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

  @doc """
  Reports whether `service`'s breaker will currently admit a call.

  Answers `:not_started` for a service that has not been started with
  `ExternalService.start/2`, which is why this is three-valued where
  `ExternalService.available?/1` is a boolean.
  """
  @spec ask(service()) :: :ok | :blown | :not_started
  def ask(service) do
    with {:ok, breaker} <- fetch(service), do: ask(service, breaker)
  end

  @doc """
  Records a single failure against `service`'s breaker.

  Use this to report a failure that happened outside a guarded call, so that it
  counts toward the breaker in the same way an in-call failure would. Enough
  melts within the configured `:within` window will open the breaker.
  """
  @spec melt(service()) :: :ok | {:error, :not_found}
  def melt(service) do
    case fetch(service) do
      {:ok, breaker} -> melt(service, breaker)
      :not_started -> {:error, :not_found}
    end
  end

  @doc """
  Closes `service`'s breaker and discards its recorded failures.

  `ExternalService.reset/1` is the same operation under a friendlier name.
  """
  @spec reset(service()) :: :ok | {:error, :not_found}
  def reset(service) do
    case fetch(service) do
      {:ok, breaker} -> reset(service, breaker)
      :not_started -> {:error, :not_found}
    end
  end

  defp fetch(service) do
    case ExternalService.State.fetch(service) do
      {:ok, %{circuit_breaker: breaker}} -> {:ok, breaker}
      :error -> :not_started
    end
  end

  # The functions below dispatch to a backend on `ExternalService`'s behalf, and
  # take the installed breaker rather than resolving it from the service state.
  # They are not part of the public API.

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
