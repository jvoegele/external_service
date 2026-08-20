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

  # The window `:auto` never goes below, and what `:within` defaulted to flatly
  # before it.
  @minimum_window 10_000

  # Opening the breaker takes `:tolerate` + 1 failures, so the window has to be wide
  # enough for that many to land inside it — and how long they take to arrive
  # depends on what one melt counts.
  #
  # This is a floor and not a guarantee. A failing call takes its retry window
  # *plus* however long its attempts run for, and nothing in a configuration states
  # the latter, so `:auto` doubles: it assumes attempts can cost about as much again
  # as the backoff between them.
  #
  # Both are measured rather than guessed at. Without the headroom, a
  # background-job shape (`tolerate: 6`, a 2s budget per call) produced a window of
  # exactly 12s and a breaker that stayed closed through twelve consecutive failing
  # calls. Without counting how many *calls* it takes to produce `:tolerate` + 1
  # melts, a `:per_attempt` service at the default `tolerate: 10` and
  # `max_attempts: 5` stayed closed through 75 seconds of total failure (issue #112).
  @attempt_headroom 2

  @doc false
  # The narrowest window in which `:tolerate` + 1 failures could possibly
  # accumulate. Below this the breaker cannot open however the traffic arrives, so
  # it is what `ExternalService.ConfigCheck` tests a hand-set `:within` against.
  @spec minimum_window(
          pos_integer() | :infinity,
          ExternalService.melt(),
          ExternalService.RetryOptions.t()
        ) :: pos_integer() | :infinity
  def minimum_window(tolerate, melt, retry_options) do
    case ExternalService.RetryOptions.window(retry_options) do
      :infinity -> :infinity
      window -> window * calls_to_open(tolerate, melt, retry_options)
    end
  end

  @doc false
  # What `:within` resolves to when it sizes itself: the minimum above, with
  # headroom for the attempt time no configuration states, and never narrower than
  # the flat default it replaces.
  @spec auto_window(
          pos_integer() | :infinity,
          ExternalService.melt(),
          ExternalService.RetryOptions.t()
        ) :: pos_integer()
  def auto_window(tolerate, melt, retry_options) do
    case minimum_window(tolerate, melt, retry_options) do
      # Unbounded retrying (only reachable under `:per_attempt`, since `:per_call`
      # rejects it) has no window to size against.
      :infinity -> @minimum_window
      minimum -> max(@minimum_window, minimum * @attempt_headroom)
    end
  end

  @doc false
  # How many failing calls it takes to produce the `:tolerate` + 1 melts that open
  # the breaker.
  @spec calls_to_open(
          pos_integer() | :infinity,
          ExternalService.melt(),
          ExternalService.RetryOptions.t()
        ) :: pos_integer()
  # `tolerate: :infinity` installs no breaker at all, so there is nothing to size.
  def calls_to_open(:infinity, _melt, _retry_options), do: 1

  # One melt per call, so `:tolerate` + 1 calls — spread across `:tolerate`
  # intervals between them.
  def calls_to_open(tolerate, :per_call, _retry_options), do: tolerate

  # Up to one melt per attempt. One call is enough only when it can produce the
  # whole budget by itself — which is *not* the common case: the defaults,
  # `tolerate: 10` against `max_attempts: 5`, need three calls.
  def calls_to_open(tolerate, :per_attempt, retry_options) do
    case attempts_per_call(retry_options) do
      :infinity -> 1
      attempts -> ceil((tolerate + 1) / attempts)
    end
  end

  # How many attempts a fully-failing call actually makes, which is not always
  # `:max_attempts`: an `:expiry` that runs out first cuts the call short, and a
  # window sized from the attempt count rather than the real one is under-sized in
  # exactly the same way this whole function exists to prevent.
  #
  # Counted from the plan rather than derived, so the two cannot disagree. The cap
  # keeps this total: a plan can be infinite, and one that long melts often enough
  # that a single call will open any breaker.
  @planning_cap 1_000

  defp attempts_per_call(retry_options) do
    case retry_options |> ExternalService.Retry.plan() |> Enum.take(@planning_cap) |> length() do
      @planning_cap -> :infinity
      delays -> delays + 1
    end
  end

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
