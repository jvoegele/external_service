defmodule ExternalService do
  @moduledoc """
  ExternalService handles all retry and circuit breaker logic for calls to external services.

  The recommended way to use it is the declarative module-based front door,
  `use ExternalService` (see `__using__/1`), which lets you configure a service's
  circuit breaker, rate limiting, and default retry options in one place. The
  functional API (`start/2`, `call/3`, and friends) is the lower-level foundation
  it is built on, and can be used directly when you need more control.

  ## Telemetry

  `ExternalService` emits [`:telemetry`](https://hexdocs.pm/telemetry) events so
  that calls to external services can be observed and instrumented. Attach a
  handler to any of the events below to forward them to your metrics or logging
  backend.

  All events carry a `:service` key in their metadata, which is the name of the
  service the event relates to.

    * `[:external_service, :call, :start]` - emitted when a guarded call begins.
      * Measurements: `:system_time`, `:monotonic_time`
      * Metadata: `:service`

    * `[:external_service, :call, :stop]` - emitted when a guarded call completes
      (including when it returns an error such as `ExternalService.RetriesExhausted`
      or `ExternalService.CircuitBreakerOpen`).
      * Measurements: `:duration`, `:monotonic_time`
      * Metadata: `:service`, `:result` (the value returned from the call)

    * `[:external_service, :call, :exception]` - emitted when a guarded call
      raises (for example a non-retriable exception, or `call!/3` raising on an
      open circuit breaker or exhausted retries).
      * Measurements: `:duration`, `:monotonic_time`
      * Metadata: `:service`, `:kind`, `:reason`, `:stacktrace`

    * `[:external_service, :call, :retry]` - emitted each time a call's function
      fails in a way that melts the circuit breaker: it returned `:retry` /
      `{:retry, reason}`, it returned a result matched by the `:retry_on`
      predicate, or it raised an exception matched by the `:retry_exceptions` retry
      option. Exceptions `:retry_exceptions` does not match neither melt the breaker
      nor emit this event. Whether another attempt is actually made depends on the
      retry options.
      * Measurements: `:count` (always `1`)
      * Metadata: `:service`, `:reason`

    * `[:external_service, :circuit_breaker, :blown]` - emitted when a call is
      rejected because the service's circuit breaker is blown.
      * Measurements: `:count` (always `1`)
      * Metadata: `:service`

    * `[:external_service, :rate_limit, :sleep]` - emitted when a call is
      throttled and put to sleep to stay within the configured rate limit.
      * Measurements: `:sleep_time` (milliseconds)
      * Metadata: `:service`
  """

  alias ExternalService.CircuitBreaker
  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.Concurrency
  alias ExternalService.RateLimited
  alias ExternalService.RateLimiter
  alias ExternalService.RetriesExhausted
  alias ExternalService.RetryOptions
  alias ExternalService.ServiceNotStarted

  require Errata
  require Logger

  @typedoc "A term that uniquely identifies an external service."
  @type service :: term()

  @typedoc "Error returned when the allowable number of retries has been exceeded"
  @type retries_exhausted :: {:error, RetriesExhausted.t()}

  @typedoc "Error returned when a service's circuit breaker is open"
  @type circuit_breaker_open :: {:error, CircuitBreakerOpen.t()}

  @typedoc "Error returned when a service has not been started with `ExternalService.start/2`"
  @type service_not_started :: {:error, ServiceNotStarted.t()}

  @typedoc "Error returned when a call is throttled beyond the rate limit `:wait` budget"
  @type rate_limited :: {:error, RateLimited.t()}

  @typedoc "Union type representing all the possible error return values"
  @type error ::
          retries_exhausted | circuit_breaker_open | service_not_started | rate_limited

  @type retriable_function_result ::
          :retry | {:retry, reason :: any()} | (function_result :: any())

  @type retriable_function :: (-> retriable_function_result())

  @typedoc """
  The function used whenever a call waits: between retry attempts, while throttled
  to stay within the rate limit, and while waiting for a concurrency slot.

  Blocking the calling process for an extended period is sometimes undesirable
  (for example in tests, where it is the difference between a suite that waits out
  every backoff and one that does not), so this can be overridden. It is called
  with the number of milliseconds to wait. Defaults to `Process.sleep/1`.
  """
  @type sleep_function :: (non_neg_integer() -> any())

  @circuit_breaker_schema [
    tolerate: [
      type: {:or, [:pos_integer, {:in, [:infinity]}]},
      default: 10,
      doc:
        "Number of failed **attempts** tolerated within the `:within` window before the " <>
          "breaker opens. Every failing retry attempt melts the breaker, so a single " <>
          "`call/3` with `max_attempts: 5` contributes up to 5 of them — `:tolerate` and " <>
          "`:max_attempts` cannot be tuned independently. `:infinity` installs no breaker " <>
          "at all: it never opens, holds no state, and cannot be combined with " <>
          "`:fault_injection`."
    ],
    within: [
      type: :pos_integer,
      default: 10_000,
      doc: "Length of the failure-counting window, in milliseconds."
    ],
    reset: [
      type: :pos_integer,
      default: 60_000,
      doc: "Milliseconds to wait before the breaker resets (closes) after it has opened."
    ],
    fault_injection: [
      type: :float,
      doc:
        "If set to a rate between `0.0` and `1.0`, randomly fails that fraction of calls. " <>
          "Intended for testing how dependents behave when this service is degraded."
    ],
    backend: [
      type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
      doc:
        "The circuit breaker implementation to use, either as a module or as a " <>
          "`{module, options}` tuple whose options are passed through to that backend. " <>
          "Defaults to the node-local `:fuse`-based breaker."
    ]
  ]

  @rate_limit_schema [
    limit: [
      type: {:or, [:pos_integer, {:in, [:infinity]}]},
      required: true,
      doc:
        "Maximum number of calls allowed within each `:per` window. `:infinity` installs " <>
          "no limiter at all — calls pass straight through, exactly as if `:rate_limit` " <>
          "had been omitted. It is meant for overriding a configured limit (a child spec " <>
          "override cannot remove a key); to have no rate limiting in the first place, " <>
          "omit `:rate_limit`. `:per` is still required, and ignored."
    ],
    per: [
      type: :pos_integer,
      required: true,
      doc: "Length of the rate-limiting window, in milliseconds."
    ],
    wait: [
      type: {:or, [{:in, [:infinity, false]}, :non_neg_integer]},
      doc:
        "How long a throttled call may wait for the rate limit to admit it. " <>
          "`:infinity` waits as long as it takes, `false` never waits, and an integer " <>
          "is a millisecond budget for the whole call. When the budget runs out the " <>
          "call is not made and an `ExternalService.RateLimited` error is returned " <>
          "(or raised by `call!/3`). Defaults to one window — `:per`, capped at 5 " <>
          "seconds — which absorbs a burst without converting sustained throttling " <>
          "into unbounded latency. Use `:infinity` for background work and pipelines, " <>
          "where sleeping is how back-pressure propagates upstream."
    ],
    backend: [
      type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
      doc:
        "The rate limiter implementation to use, either as a module or as a " <>
          "`{module, options}` tuple whose options are passed through to that backend. " <>
          "Defaults to `ExternalService.RateLimiter.Local`. Use " <>
          "`ExternalService.RateLimiter.Hammer` for a limit shared across a cluster."
    ]
  ]

  @concurrency_schema [
    limit: [
      type: :pos_integer,
      required: true,
      doc: "Maximum number of calls allowed to be in flight against the service at once."
    ],
    reclaim_after: [
      type: :pos_integer,
      required: true,
      doc:
        "Milliseconds after which a held slot is considered abandoned and may be reused. " <>
          "A slot is normally released as soon as the call finishes, but a caller killed " <>
          "from outside — including by the ordinary `:shutdown` a supervisor sends while " <>
          "draining — never runs its release. This bounds how long such a slot is lost. " <>
          "Required rather than defaulted: it must exceed the longest legitimate call, " <>
          "which depends on the timeout configured in your HTTP client. Setting it too " <>
          "low silently admits more than `:limit`."
    ],
    wait: [
      type: {:or, [{:in, [false]}, :non_neg_integer]},
      default: false,
      doc:
        "How long a call may wait for a slot before being shed. `false` (the default) " <>
          "sheds immediately; an integer is a millisecond budget. A short budget absorbs " <>
          "bursts without allowing a pile-up, since waiting callers hold no slot and are " <>
          "bounded by arrival rate times the budget. Unlike the rate limiter's `:wait`, " <>
          "`:infinity` is not accepted — an unbounded wait is the pile-up a concurrency " <>
          "limit exists to prevent."
    ]
  ]

  @start_schema [
    circuit_breaker: [
      type: :keyword_list,
      default: [],
      keys: @circuit_breaker_schema,
      doc: "Circuit breaker configuration."
    ],
    rate_limit: [
      type: :keyword_list,
      keys: @rate_limit_schema,
      doc: "Optional rate-limiting configuration. Omit for no rate limiting."
    ],
    concurrency: [
      type: :keyword_list,
      keys: @concurrency_schema,
      doc:
        "Optional concurrency limit (the bulkhead pattern). Omit for no limit. See " <>
          "`ExternalService.Concurrency`."
    ],
    retry: [
      type: {:or, [:keyword_list, {:struct, RetryOptions}]},
      default: [],
      doc:
        "Default retry options for the service, used by `call/2`. See " <>
          "`ExternalService.RetryOptions` for the available keys."
    ],
    sleep_function: [
      type: {:fun, 1},
      doc:
        "Overrides the function used whenever a call waits — between retry attempts, " <>
          "while rate limited, and while waiting for a concurrency slot. Called with the " <>
          "number of milliseconds to wait. Defaults to `Process.sleep/1`; overriding it lets " <>
          "tests exercise backoff and throttling without waiting for them."
    ]
  ]

  @typedoc "Options for `start/2`. See the schema documented under `start/2`."
  @type options :: keyword()

  defmodule State do
    @moduledoc false

    # Per-service configuration is stored in `:persistent_term`. The state for a
    # service is written once by `ExternalService.start/2` and read on every call,
    # which is exactly the access pattern `:persistent_term` is optimized for:
    # lock-free reads with no process to message or crash. This replaces the
    # previous unsupervised `Agent`.

    defstruct [:service, :circuit_breaker, :rate_limit, :concurrency, :retry_options, :sleep]

    @type t :: %__MODULE__{
            service: ExternalService.service(),
            circuit_breaker: ExternalService.CircuitBreaker.t(),
            rate_limit: ExternalService.RateLimiter.t(),
            concurrency: ExternalService.Concurrency.t(),
            retry_options: ExternalService.RetryOptions.t(),
            sleep: ExternalService.sleep_function()
          }

    def init(service, circuit_breaker, rate_limit, concurrency, retry_options, sleep) do
      state = %__MODULE__{
        service: service,
        circuit_breaker: circuit_breaker,
        rate_limit: rate_limit,
        concurrency: concurrency,
        retry_options: retry_options,
        sleep: sleep
      }

      :persistent_term.put(key(service), state)
      state
    end

    def get(service), do: :persistent_term.get(key(service))

    def fetch(service) do
      {:ok, :persistent_term.get(key(service))}
    rescue
      ArgumentError -> :error
    end

    def delete(service), do: :persistent_term.erase(key(service))

    defp key(service), do: {__MODULE__, service}
  end

  @doc """
  Initializes the circuit breaker (and optional rate limiting and default retry
  options) for a specific service.

  The `service` is a term that uniquely identifies an external service within the
  scope of an application.

  ## Options

  #{NimbleOptions.docs(@start_schema)}
  """
  @spec start(service(), options()) :: :ok
  def start(service, options \\ []) do
    options = validate!(service, options)
    validate_breaker_combination!(service, options[:circuit_breaker])

    circuit_breaker = CircuitBreaker.install(service, options[:circuit_breaker])

    rate_limit =
      RateLimiter.new(
        service,
        options[:rate_limit],
        Keyword.take(options, [:sleep_function])
      )

    concurrency =
      Concurrency.new(
        service,
        options[:concurrency],
        Keyword.take(options, [:sleep_function])
      )

    retry_options = RetryOptions.new(options[:retry])

    sleep = Keyword.get(options, :sleep_function, &Process.sleep/1)

    State.init(service, circuit_breaker, rate_limit, concurrency, retry_options, sleep)
    :ok
  end

  # NimbleOptions would reject `concurrency: [wait: :infinity]` with a type error
  # that does not explain itself. Anyone reaching for it is coming from the rate
  # limiter's `:wait`, where `:infinity` is both accepted and often correct, so
  # the difference is worth spelling out.
  defp validate!(service, options) do
    if get_in(options, [:concurrency, :wait]) == :infinity do
      raise ArgumentError, """
      ExternalService.start(#{inspect(service)}, ...) sets \
      concurrency: [wait: :infinity], which is not allowed. Waiting forever for a \
      slot is the unbounded pile-up a concurrency limit exists to prevent — every \
      caller over the limit would park indefinitely, which is the behavior you get \
      by not configuring `:concurrency` at all.

      Use a bounded budget to absorb bursts:

          concurrency: [limit: 25, reclaim_after: 30_000, wait: 50]

      Or shed immediately, which is the default:

          concurrency: [limit: 25, reclaim_after: 30_000]

      The rate limiter's `:wait` does accept `:infinity`, because sleeping until a \
      quota refills is bounded by the quota itself. A slot only frees when another \
      call finishes, so nothing bounds it here.
      """
    end

    NimbleOptions.validate!(options, @start_schema)
  end

  # `:fault_injection` exists to make a breaker report blown; `tolerate: :infinity`
  # promises it never will. Silently letting either win would make the other
  # option a lie, so the combination is rejected where it is written.
  defp validate_breaker_combination!(service, circuit_breaker_options) do
    tolerate = circuit_breaker_options[:tolerate]
    fault_injection = circuit_breaker_options[:fault_injection]

    if tolerate == :infinity and not is_nil(fault_injection) do
      raise ArgumentError, """
      ExternalService.start(#{inspect(service)}, ...) sets both \
      circuit_breaker: [tolerate: :infinity] and :fault_injection, which contradict \
      each other. :tolerate: :infinity installs no breaker, so there is nothing for \
      :fault_injection to blow.

      Drop whichever you did not mean:

          # a breaker that never opens
          circuit_breaker: [tolerate: :infinity]

          # a breaker that fails #{inspect(fault_injection)} of calls, for testing dependents
          circuit_breaker: [fault_injection: #{inspect(fault_injection)}]
      """
    end

    :ok
  end

  @doc """
  Stops the fuse for a specific service.

  Stopping is idempotent: it is safe to call on a service that was never started
  or has already been stopped.
  """
  @spec stop(service()) :: :ok
  def stop(service) do
    case State.fetch(service) do
      {:ok, state} -> CircuitBreaker.remove(service, state.circuit_breaker)
      # A service with no state was never started (or has already been stopped),
      # so there is nothing to tear down — which is what makes stop/1 idempotent.
      :error -> :ok
    end

    State.delete(service)
    :ok
  end

  @doc """
  Resets the circuit breaker for the given service.

  After reset, the breaker will be closed with no recorded failures.
  """
  @spec reset(service()) :: :ok | {:error, :not_found}
  def reset(service), do: CircuitBreaker.reset(service)

  @doc """
  Resets every stateful mechanism for the given service: the circuit breaker, the
  rate limiter, and the concurrency limit.

  `reset/1` closes the breaker only, and deliberately leaves the rate limiter
  alone — clearing a limiter in production releases a burst at the service, which
  is rarely what someone closing a breaker meant to do. This function is for when
  you do want a clean slate.

  Its main use is between tests. A service's state is global — it lives in
  `:persistent_term` and `:fuse`, keyed on the service term — so a test that
  trips the breaker or drains the rate limit budget leaves it that way for
  whatever runs next:

      setup do
        ExternalService.reset_all(MyApp.Stripe)
        :ok
      end

  A service with no rate limit configured resets just the breaker. One that was
  never started answers `{:error, :not_found}`, exactly as `reset/1` does.

  Note that this shares state rather than isolating it, so it does not make
  concurrent tests independent — see the [Testing](testing.md) guide.
  """
  @spec reset_all(service()) :: :ok | {:error, :not_found}
  def reset_all(service) do
    with :ok <- CircuitBreaker.reset(service),
         :ok <- RateLimiter.reset(service) do
      Concurrency.reset(service)
    end
  end

  @doc """
  Returns `true` if the service is currently available, meaning its circuit
  breaker is not blown.

  This is useful for the circuit breaker pattern: before kicking off expensive
  work, you can check whether the services it depends on are available and bail
  out early (returning a degraded response) if any of them are not.

  A service that has not been started (see `start/2`) is reported as not
  available. Note that availability can change between this check and a
  subsequent `call/3`, so this is a best-effort signal, not a guarantee.

  ## Examples

      if ExternalService.available?(:payments) do
        charge(order)
      else
        {:error, :payments_unavailable}
      end
  """
  @spec available?(service()) :: boolean()
  def available?(service), do: CircuitBreaker.ask(service) == :ok

  @doc """
  Returns `true` if the service's circuit breaker is currently blown.

  A service that has not been started (see `start/2`) is _not_ considered blown;
  use `available?/1` if you want "ready to use" semantics that also account for
  services that were never started.
  """
  @spec blown?(service()) :: boolean()
  def blown?(service), do: CircuitBreaker.ask(service) == :blown

  @doc """
  Returns `true` if `service` has no concurrency slot free right now.

  Completes the trio with `available?/1` (is the breaker closed?) and
  `rate_limited?/1` (would a call be throttled?). A service with no
  `:concurrency` limit configured — including one that was never started — is
  never saturated, since nothing is holding calls back.

  Like the others this is a best-effort signal: a slot can be taken or released
  between the check and a subsequent call, so it lets you bail out early rather
  than replacing handling of `ExternalService.ServiceSaturated` from the call
  itself.
  """
  @spec saturated?(service()) :: boolean()
  def saturated?(service) do
    case Concurrency.limit(service) do
      nil -> false
      limit -> Concurrency.in_flight(service) >= limit
    end
  end

  @doc """
  Returns `true` only if every service in `fuse_names` is `available?/1`.

  Useful for guarding work that depends on several services at once.

  ## Examples

      if ExternalService.all_available?([:payments, :inventory]) do
        place_order(order)
      else
        {:error, :service_unavailable}
      end
  """
  @spec all_available?([service()]) :: boolean()
  def all_available?(services), do: Enum.all?(services, &available?/1)

  @doc """
  Returns `true` if a call to the service would currently be throttled by its
  rate limit.

  This is a *read*: it consumes none of the service's budget, so it is safe to
  ask speculatively before committing to expensive work. A service with no rate
  limit configured is never rate limited.

  As with `available?/1`, this is a best-effort signal — the answer can change
  between the check and a subsequent `call/3`. Use
  `ExternalService.RateLimiter.peek/1` when you want to know *how long* the wait
  would be rather than merely whether there is one.

  ## Examples

      if ExternalService.rate_limited?(:payments) do
        {:error, :busy}
      else
        charge(order)
      end
  """
  @spec rate_limited?(service()) :: boolean()
  def rate_limited?(service), do: match?({:wait, _}, RateLimiter.peek(service))

  @doc """
  Executes a function for the given service, handling retry and circuit breaker logic.

  `ExternalService.start/2` must be called for the service before using `call`.

  The provided function can indicate that a retry should be performed by returning the atom
  `:retry` or a tuple of the form `{:retry, reason}`, where `reason` is any arbitrary term. Any
  other result is considered successful, so the operation will not be retried and the result of
  the function will be returned as the result of `call`.

  For functions that were not written to return `:retry`/`{:retry, reason}`, the `:retry_on` retry
  option takes a predicate that is run on the return value; when it returns a truthy value the call
  is retried as though the function had returned `{:retry, result}` (the result becomes the retry
  reason and the circuit breaker melts). An explicit `:retry`/`{:retry, reason}` return always
  takes precedence over the predicate.

  Raised exceptions are only retried if the `:retry_exceptions` retry option matches them (it
  defaults to `[]`, matching nothing); otherwise they propagate to the caller untouched. That
  option takes either a list of exception modules or a predicate run on the exception itself, which
  can decide per *instance* rather than per type. An exception that is not retried also does *not*
  melt the circuit breaker — `:retry_exceptions` governs both retrying and whether a raised
  exception counts as a circuit-breaker failure. When retries are spent on an exception that *was*
  being retried, the original exception is re-raised with its original stacktrace.

  `retry_opts` may be a `t:ExternalService.RetryOptions.t/0` struct or a keyword list of retry
  options. A keyword list is treated as per-call *overrides*: it is merged onto the service's
  configured default retry options (from `start/2`), so it overrides only the keys it lists and
  inherits the rest. A `RetryOptions` struct, being a complete set of options, replaces the
  service defaults entirely. When omitted (the two-argument form `call/2`), the service's
  configured defaults are used.
  """
  @spec call(service(), retriable_function()) :: error | (function_result :: any)
  def call(service, function) when is_function(function) do
    call(service, service_retry_options(service), function)
  end

  @spec call(service(), RetryOptions.t() | keyword(), retriable_function()) ::
          error | (function_result :: any)
  def call(service, retry_opts, function) do
    retry_opts = resolve_retry_options(service, retry_opts)

    call_span(service, fn ->
      case call_with_retry(service, retry_opts, function) do
        {:no_retry, result} -> result
        {:error, :retry} -> {:error, retries_exhausted(service, :reason_unknown)}
        {:error, {:retry, reason}} -> {:error, retries_exhausted(service, reason)}
        {:error, {:circuit_breaker_open, service}} -> {:error, circuit_breaker_open(service)}
        {:error, {:not_started, service}} -> {:error, service_not_started(service)}
        {:error, {:rate_limited, service, after_ms}} -> {:error, rate_limited(service, after_ms)}
        {:error, {:saturated, service}} -> {:error, Concurrency.error(service)}
      end
    end)
  end

  @doc """
  Like `call/3`, but raises an exception if retries are exhausted or the circuit breaker is open.
  """
  @spec call!(service(), retriable_function()) :: function_result :: any | no_return
  def call!(service, function) when is_function(function) do
    call!(service, service_retry_options(service), function)
  end

  @spec call!(service(), RetryOptions.t() | keyword(), retriable_function()) ::
          function_result :: any | no_return
  def call!(service, retry_opts, function) do
    retry_opts = resolve_retry_options(service, retry_opts)

    call_span(service, fn ->
      case call_with_retry(service, retry_opts, function) do
        {:no_retry, result} -> result
        {:error, :retry} -> raise retries_exhausted(service, :reason_unknown)
        {:error, {:retry, reason}} -> raise retries_exhausted(service, reason)
        {:error, {:circuit_breaker_open, service}} -> raise circuit_breaker_open(service)
        {:error, {:not_started, service}} -> raise service_not_started(service)
        {:error, {:rate_limited, service, after_ms}} -> raise rate_limited(service, after_ms)
        {:error, {:saturated, service}} -> raise Concurrency.error(service)
      end
    end)
  end

  defp service_retry_options(service) do
    case State.fetch(service) do
      {:ok, %{retry_options: %RetryOptions{} = retry_options}} -> retry_options
      _ -> %RetryOptions{}
    end
  end

  # A `%RetryOptions{}` struct is a complete set of options and is used as-is. A
  # keyword list is treated as per-call *overrides*, merged onto the service's
  # configured default retry options so that, e.g., `call([max_attempts: 2], fun)`
  # tweaks only `:max_attempts` and inherits the rest of the service's config.
  defp resolve_retry_options(_service, %RetryOptions{} = retry_opts), do: retry_opts

  defp resolve_retry_options(service, retry_opts) when is_list(retry_opts),
    do: RetryOptions.merge(service_retry_options(service), retry_opts)

  @doc """
  Asynchronous version of `ExternalService.call`.

  Returns a `Task` that may be used to retrieve the result of the async call.
  """
  @spec call_async(service(), retriable_function()) :: Task.t()
  def call_async(service, function) when is_function(function) do
    call_async(service, service_retry_options(service), function)
  end

  @spec call_async(service(), RetryOptions.t() | keyword(), retriable_function()) :: Task.t()
  def call_async(service, retry_opts, function) do
    Task.async(fn -> call(service, retry_opts, function) end)
  end

  @doc """
  Parallel, streaming version of `ExternalService.call`.

  See `call_async_stream/5` for full documentation.
  """
  @spec call_async_stream(Enumerable.t(), service(), (any() -> retriable_function_result())) ::
          Enumerable.t()
  def call_async_stream(enumerable, service, function) when is_function(function),
    do: call_async_stream(enumerable, service, nil, [], function)

  @doc """
  Parallel, streaming version of `ExternalService.call`.

  See `call_async_stream/5` for full documentation.
  """
  @spec call_async_stream(
          Enumerable.t(),
          service(),
          RetryOptions.t() | (async_opts :: list()),
          (any() -> retriable_function_result())
        ) :: Enumerable.t()
  def call_async_stream(enumerable, service, retry_opts_or_async_opts, function)

  def call_async_stream(enumerable, service, %RetryOptions{} = retry_opts, function)
      when is_function(function),
      do: call_async_stream(enumerable, service, retry_opts, [], function)

  def call_async_stream(enumerable, service, async_opts, function)
      when is_list(async_opts) and is_function(function),
      do: call_async_stream(enumerable, service, nil, async_opts, function)

  @doc """
  Parallel, streaming version of `ExternalService.call`.

  This function uses Elixir's built-in `Task.async_stream/3` function and the description below is
  taken from there.

  Returns a stream that runs the given function `function` concurrently on each
  item in `enumerable`.

  Each `enumerable` item is passed as argument to the given function `function`
  and processed by its own task. The tasks will be linked to the current
  process, similarly to `async/1`.
  """
  @spec call_async_stream(
          Enumerable.t(),
          service(),
          RetryOptions.t() | keyword() | nil,
          async_opts :: list(),
          (any() -> retriable_function_result())
        ) :: Enumerable.t()
  def call_async_stream(enumerable, service, retry_opts, async_opts, function)
      when is_list(async_opts) and is_function(function) do
    retry_opts = retry_opts || service_retry_options(service)
    fun = fn item -> call(service, retry_opts, fn -> function.(item) end) end
    Task.async_stream(enumerable, fun, async_opts)
  end

  @spec call_with_retry(service(), RetryOptions.t(), retriable_function()) ::
          {:no_retry, function_result :: any()}
          | {:error, :retry}
          | {:error, {:retry, reason :: any()}}
          | {:error, {:circuit_breaker_open, service()}}
          | {:error, {:not_started, service()}}
          | {:error, {:rate_limited, service(), non_neg_integer()}}
          | {:error, {:saturated, service()}}
  defp call_with_retry(service, retry_opts, function) do
    # The service state is read once per call rather than once per attempt: it is
    # written by `start/2` and never changes, and it is what tells us whether the
    # service was started at all (the breaker backend only reports open/closed).
    case State.fetch(service) do
      :error ->
        log_service_not_started(service)
        {:error, {:not_started, service}}

      {:ok, state} ->
        call_with_retry(service, state, retry_opts, function)
    end
  end

  defp call_with_retry(service, state, retry_opts, function) do
    attempt = fn ->
      case CircuitBreaker.ask(service, state.circuit_breaker) do
        :ok ->
          try_function(service, state, retry_opts, function)

        :blown ->
          emit_blown(service)
          throw(:blown)
      end
    end

    retry_opts
    |> RetryOptions.delay_stream()
    |> run_attempts(attempt, state.sleep)
    |> case do
      {:no_retry, _} = result ->
        result

      {:error, :retry} = error ->
        error

      {:error, {:retry, _reason}} = error ->
        error

      # Retries are spent on an exception we were retrying: re-raise the original
      # with its original stacktrace, so the trace still points at the code that
      # raised rather than at this retry loop.
      {:error, {:retry_exception, exception, stacktrace}} ->
        reraise(exception, stacktrace)
    end
  catch
    :blown ->
      {:error, {:circuit_breaker_open, service}}

    {:rate_limited, retry_after} ->
      {:error, {:rate_limited, service, retry_after}}

    :saturated ->
      {:error, {:saturated, service}}
  end

  # The retry loop. Each element of `delays` is how long to sleep *before* the
  # attempt that follows it, so the first attempt is made immediately and the
  # stream running out is what ends the retrying. An attempt that does not ask for
  # another wins immediately; otherwise the last attempt's answer is the call's,
  # which is how an exhausted call reports the reason it kept retrying.
  #
  # Sleeping goes through the service's `:sleep_function` so that a test can drive
  # backoff without waiting for it.
  defp run_attempts(delays, attempt, sleep) do
    case attempt.() do
      {:no_retry, _} = result -> result
      retry -> retry_attempts(delays, attempt, sleep, retry)
    end
  end

  defp retry_attempts(delays, attempt, sleep, first_retry) do
    Enum.reduce_while(delays, first_retry, fn delay, _previous ->
      sleep.(delay)
      continue_unless_settled(attempt.())
    end)
  end

  defp continue_unless_settled({:no_retry, _} = result), do: {:halt, result}
  defp continue_unless_settled(retry), do: {:cont, retry}

  @spec try_function(service, State.t(), RetryOptions.t(), retriable_function) ::
          {:error, {:retry, any}}
          | {:error, :retry}
          | {:error, {:retry_exception, Exception.t(), Exception.stacktrace()}}
          | {:no_retry, any}
          | no_return
  defp try_function(service, state, retry_opts, function) do
    # The concurrency slot is taken inside the rate limiter rather than around
    # it, so a caller sleeping on the `:wait` budget holds no slot: the limit
    # counts calls actually in flight against the service. It is per attempt,
    # so a call sitting in backoff between attempts holds nothing either.
    guarded = fn -> Concurrency.call(state.concurrency, function) end

    case RateLimiter.call(state.rate_limit, guarded) do
      # No slot was free. The wrapped function never ran, so as with rate
      # limiting there is nothing to retry and no failure to melt the breaker.
      {Concurrency, :saturated} ->
        throw(:saturated)

      # The wrapped function never ran, so there is nothing to retry and no
      # failure to hold against the circuit breaker. Thrown rather than returned
      # so that it escapes the retry loop rather than being treated as a result.
      {RateLimiter, :rate_limited, retry_after} ->
        throw({:rate_limited, retry_after})

      {:retry, reason} ->
        emit_retry(service, reason)
        melt(service, state)
        {:error, {:retry, reason}}

      :retry ->
        emit_retry(service, :reason_unknown)
        melt(service, state)
        {:error, :retry}

      result ->
        maybe_retry_on_result(service, state, retry_opts.retry_on, result)
    end
  rescue
    error ->
      # A raised exception only counts as a failure (melting the circuit breaker)
      # when it is one we would retry on. Exceptions not matched by `:retry_exceptions`
      # propagate untouched and leave the breaker alone — `:retry_exceptions` governs
      # both retrying and melting.
      if retriable_exception?(service, error, retry_opts.retry_exceptions) do
        emit_retry(service, error)
        melt(service, state)
        {:error, {:retry_exception, error, __STACKTRACE__}}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp melt(service, state), do: CircuitBreaker.melt(service, state.circuit_breaker)

  # When a `:retry_on` predicate is configured, a result it matches is treated as a
  # retry — melting the breaker and using the result itself as the retry reason —
  # exactly like an explicit `:retry` return (which is handled before we get here,
  # so an explicit return always takes precedence). With no predicate, or when it
  # does not match, the result is returned untouched.
  defp maybe_retry_on_result(_service, _state, nil, result), do: {:no_retry, result}

  defp maybe_retry_on_result(service, state, predicate, result) when is_function(predicate, 1) do
    if apply_predicate(service, :retry_on, predicate, result) do
      emit_retry(service, result)
      melt(service, state)
      {:error, {:retry, result}}
    else
      {:no_retry, result}
    end
  end

  # `:retry_exceptions` is either a list of exception modules — an exception is
  # retriable when its struct is one of them — or a predicate on the exception
  # itself, which can decide per instance rather than per type.
  defp retriable_exception?(service, error, predicate) when is_function(predicate, 1) do
    apply_predicate(service, :retry_exceptions, predicate, error)
  end

  defp retriable_exception?(_service, error, retry_exceptions) when is_list(retry_exceptions) do
    Enum.any?(retry_exceptions, fn module -> is_struct(error, module) end)
  end

  # A retry predicate is arbitrary user code, and `:retry_exceptions` runs it on a
  # path that is already failing — so a bug in the predicate would otherwise become
  # the failure the caller sees, in place of the exception it was called to
  # classify. Any way of not returning an answer (raise, throw, or exit) is treated
  # as "this predicate did not classify the value", which means no retry: retrying
  # is the consequential interpretation, and a predicate that just crashed has
  # demonstrated it cannot authorize it. The call's own result or exception is left
  # exactly as it was, and the warning is what makes the broken predicate findable.
  defp apply_predicate(service, option, predicate, value) do
    !!predicate.(value)
  rescue
    error -> predicate_failed(service, option, :error, error, __STACKTRACE__)
  catch
    kind, reason -> predicate_failed(service, option, kind, reason, __STACKTRACE__)
  end

  defp predicate_failed(service, option, kind, reason, stacktrace) do
    Logger.warning("""
    The #{inspect(option)} predicate for #{inspect(service)} did not return, so the \
    call was treated as not retriable and its own result or exception was left \
    untouched. Fix the predicate: it must answer for every value it can be given, \
    including ones it does not recognise.

    #{Exception.format(kind, reason, stacktrace)}\
    """)

    false
  end

  defp retries_exhausted(service, reason) do
    # The retry reason can be any term, so it is carried in `:context` rather than
    # in Errata's `:reason` field (which is an atom classifier). When it happens to
    # be an exception — any Errata error included — it is *also* set as the
    # `:cause`, which is the slot Errata means for it: that is what makes
    # `Errata.root_cause/1` reach the underlying failure and
    # `Errata.format_chain/1` print the chain. A non-exception reason leaves
    # `:cause` unset rather than
    # wrapping a bare term that would only add noise to the formatted output.
    Errata.create(RetriesExhausted,
      context: %{service: service, reason: reason},
      cause: if(is_exception(reason), do: reason)
    )
  end

  defp circuit_breaker_open(service) do
    Errata.create(CircuitBreakerOpen, context: %{service: service})
  end

  defp service_not_started(service) do
    Errata.create(ServiceNotStarted, context: %{service: service})
  end

  defp rate_limited(service, retry_after) do
    Errata.create(RateLimited, context: %{service: service, retry_after: retry_after})
  end

  defp call_span(service, fun) do
    :telemetry.span([:external_service, :call], %{service: service}, fn ->
      result = fun.()
      {result, %{service: service, result: result}}
    end)
  end

  defp emit_retry(service, reason) do
    :telemetry.execute(
      [:external_service, :call, :retry],
      %{count: 1},
      %{service: service, reason: reason}
    )
  end

  defp emit_blown(service) do
    :telemetry.execute(
      [:external_service, :circuit_breaker, :blown],
      %{count: 1},
      %{service: service}
    )
  end

  defp log_service_not_started(service) do
    Logger.error(service_not_started_message(service))
  end

  defp service_not_started_message(service) do
    service = inspect(service)

    "Service #{service} has not been started. To initialize it, call " <>
      "ExternalService.start(#{service}) in your application start code."
  end

  @doc false
  # Deep merges child-spec overrides onto the options given to `use
  # ExternalService`, for the `start_link/1` the macro below generates.
  #
  # This replaces `DeepMerge.deep_merge/2`, and reproduces its rules for the
  # shapes these options can take:
  #
  #   * two keyword-shaped lists merge key by key, recursing into values that are
  #     themselves keyword-shaped;
  #   * an **empty** override list leaves a keyword-shaped original alone rather
  #     than clearing it, so `start_link(circuit_breaker: [])` is a no-op;
  #   * two plain maps merge the same way, which no option shape currently
  #     produces but which `DeepMerge` did, so the port keeps it;
  #   * anything else — a struct, a function, a tuple, a plain list such as
  #     `:retry_exceptions`, a scalar — is replaced wholesale by the override.
  #
  # Note that the second and third rules interact: `retry_exceptions: []` *does*
  # clear `[RuntimeError]`, because the original is not keyword-shaped and so the
  # override simply wins. `merge_config_test.exs` pins all of this.
  #
  # "Keyword-shaped" is `DeepMerge`'s own test — a list whose head is a two-tuple
  # — rather than `Keyword.keyword?/1`, which would walk the whole list.
  @spec __merge_config__(keyword(), keyword()) :: keyword()
  def __merge_config__(original, override), do: merge_values(original, override)

  defp merge_values([{_, _} | _] = original, [{_, _} | _] = override),
    do: Keyword.merge(original, override, fn _key, old, new -> merge_values(old, new) end)

  defp merge_values([{_, _} | _] = original, []), do: original

  defp merge_values(original, override)
       when is_map(original) and is_map(override) and
              not is_struct(original) and not is_struct(override),
       do: Map.merge(original, override, fn _key, old, new -> merge_values(old, new) end)

  defp merge_values(_original, override), do: override

  @doc """
  Defines a module-based gateway to an external service.

  `use ExternalService` generates a small, declarative wrapper around the
  functional API. Configure the circuit breaker, rate limiting, and default
  retry options at the module level, then start the module under a supervisor
  and call the service through the generated `call/1` (and friends).

  ## Example

      defmodule MyApp.Stripe do
        use ExternalService,
          circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
          rate_limit: [limit: 100, per: :timer.seconds(1), wait: :timer.seconds(1)],
          retry: [max_attempts: 5, backoff: :exponential, jitter: true]

        def charge(params) do
          call fn ->
            case Stripe.charge(params) do
              {:ok, result} -> {:ok, result}
              {:error, %{status: status}} when status in 500..599 -> :retry
              other -> other
            end
          end
        end
      end

  Start it under your supervision tree:

      children = [MyApp.Stripe]
      Supervisor.start_link(children, strategy: :one_for_one)

  Configuration can be overridden when starting (useful in tests), and is deep
  merged with the options given to `use`:

      {MyApp.Stripe, circuit_breaker: [tolerate: 1], retry: [max_attempts: 1]}

  ## Options

  Accepts the same options as `start/2` (`:circuit_breaker`, `:rate_limit`,
  `:retry`, `:sleep_function`), plus:

    * `:name` - the term that identifies the service. Defaults to the module name.

  ## Generated functions

    * `call/1`, `call/2`, `call!/1`, `call!/2`
    * `call_async/1`, `call_async/2`
    * `call_async_stream/2`, `call_async_stream/3`, `call_async_stream/4`
    * `available?/0`, `blown?/0`, `saturated?/0`, `reset/0`, `reset_all/0`
    * `child_spec/1`, `start_link/1`
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @__external_service__ Keyword.get(opts, :name, __MODULE__)
      @__external_service_opts__ Keyword.delete(opts, :name)

      @doc false
      def child_spec(overrides \\ []) do
        %{id: __MODULE__, type: :worker, start: {__MODULE__, :start_link, [overrides]}}
      end

      @doc """
      Starts the service (installing its circuit breaker and rate limiter) linked
      to the current process.

      `overrides` are deep merged with the options given to `use ExternalService`.
      """
      def start_link(overrides \\ []) do
        config = ExternalService.__merge_config__(@__external_service_opts__, overrides)

        Agent.start_link(
          fn -> :ok = ExternalService.start(@__external_service__, config) end,
          name: Module.concat(__MODULE__, "Starter")
        )
      end

      @doc "Executes `function` for this service. See `ExternalService.call/3`."
      def call(function) when is_function(function),
        do: ExternalService.call(@__external_service__, function)

      def call(retry_opts, function),
        do: ExternalService.call(@__external_service__, retry_opts, function)

      @doc "Like `call/2`, but raises on failure. See `ExternalService.call!/3`."
      def call!(function) when is_function(function),
        do: ExternalService.call!(@__external_service__, function)

      def call!(retry_opts, function),
        do: ExternalService.call!(@__external_service__, retry_opts, function)

      @doc "Asynchronous version of `call/2`. See `ExternalService.call_async/3`."
      def call_async(function) when is_function(function),
        do: ExternalService.call_async(@__external_service__, function)

      def call_async(retry_opts, function),
        do: ExternalService.call_async(@__external_service__, retry_opts, function)

      @doc "Parallel, streaming version of `call/2`. See `ExternalService.call_async_stream/5`."
      def call_async_stream(enumerable, function) when is_function(function),
        do: ExternalService.call_async_stream(enumerable, @__external_service__, function)

      @doc "See `call_async_stream/2`."
      def call_async_stream(enumerable, retry_opts_or_async_opts, function),
        do:
          ExternalService.call_async_stream(
            enumerable,
            @__external_service__,
            retry_opts_or_async_opts,
            function
          )

      @doc "See `call_async_stream/2`."
      def call_async_stream(enumerable, retry_opts, async_opts, function),
        do:
          ExternalService.call_async_stream(
            enumerable,
            @__external_service__,
            retry_opts,
            async_opts,
            function
          )

      @doc "Returns `true` if the service is available. See `ExternalService.available?/1`."
      def available?, do: ExternalService.available?(@__external_service__)

      @doc "Returns `true` if the circuit breaker is open. See `ExternalService.blown?/1`."
      def blown?, do: ExternalService.blown?(@__external_service__)

      @doc "Returns `true` if no concurrency slot is free. See `ExternalService.saturated?/1`."
      def saturated?, do: ExternalService.saturated?(@__external_service__)

      @doc "Resets the circuit breaker. See `ExternalService.reset/1`."
      def reset, do: ExternalService.reset(@__external_service__)

      @doc "Resets the circuit breaker and the rate limiter. See `ExternalService.reset_all/1`."
      def reset_all, do: ExternalService.reset_all(@__external_service__)
    end
  end
end
