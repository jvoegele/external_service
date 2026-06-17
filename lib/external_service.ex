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
      fails in a way that melts the circuit breaker (it returned `:retry` /
      `{:retry, reason}` or raised). Whether another attempt is actually made
      depends on the retry options.
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

  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RateLimit
  alias ExternalService.RetriesExhausted
  alias ExternalService.RetryOptions
  alias ExternalService.ServiceNotStarted
  alias :fuse, as: Fuse

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

  @typedoc "Union type representing all the possible error return values"
  @type error :: retries_exhausted | circuit_breaker_open | service_not_started

  @type retriable_function_result ::
          :retry | {:retry, reason :: any()} | (function_result :: any())

  @type retriable_function :: (-> retriable_function_result())

  @typedoc """
  The sleep function called when a call is throttled to stay within the rate limit.

  Blocking the calling process for an extended period is sometimes undesirable
  (for example in tests), so this can be overridden. Defaults to `Process.sleep/1`.
  """
  @type sleep_function :: (non_neg_integer() -> any())

  @circuit_breaker_schema [
    tolerate: [
      type: :pos_integer,
      default: 10,
      doc: "Number of failures tolerated within the `:within` window before the breaker opens."
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
    ]
  ]

  @rate_limit_schema [
    limit: [
      type: :pos_integer,
      required: true,
      doc: "Maximum number of calls allowed within each `:per` window."
    ],
    per: [
      type: :pos_integer,
      required: true,
      doc: "Length of the rate-limiting window, in milliseconds."
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
        "Overrides the function used to sleep while rate limited (defaults to `Process.sleep/1`)."
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

    defstruct [:service, :fuse_options, :rate_limit, :retry_options]

    def init(service, fuse_options, rate_limit, retry_options) do
      state = %__MODULE__{
        service: service,
        fuse_options: fuse_options,
        rate_limit: rate_limit,
        retry_options: retry_options
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
    options = NimbleOptions.validate!(options, @start_schema)
    circuit_breaker = options[:circuit_breaker]

    fuse_opts = {fuse_strategy(circuit_breaker), {:reset, circuit_breaker[:reset]}}
    :ok = Fuse.install(service, fuse_opts)

    rate_limit =
      RateLimit.new(
        service,
        rate_limit_spec(options[:rate_limit]),
        Keyword.take(options, [:sleep_function])
      )

    State.init(service, fuse_opts, rate_limit, RetryOptions.new(options[:retry]))
    :ok
  end

  defp fuse_strategy(circuit_breaker) do
    tolerate = circuit_breaker[:tolerate]
    within = circuit_breaker[:within]

    case circuit_breaker[:fault_injection] do
      nil -> {:standard, tolerate, within}
      rate -> {:fault_injection, rate, tolerate, within}
    end
  end

  defp rate_limit_spec(nil), do: nil
  defp rate_limit_spec(rate_limit), do: {rate_limit[:limit], rate_limit[:per]}

  @doc """
  Stops the fuse for a specific service.

  Stopping is idempotent: it is safe to call on a service that was never started
  or has already been stopped.
  """
  @spec stop(service()) :: :ok
  def stop(service) do
    # `:fuse.remove/1` returns `{:error, :not_found}` for an unknown fuse; treat
    # that as success so that stop/1 is idempotent.
    _ = Fuse.remove(service)
    State.delete(service)
    :ok
  end

  @doc """
  Resets the circuit breaker for the given service.

  After reset, the breaker will be closed with no recorded failures.
  """
  @spec reset(service()) :: :ok | {:error, :not_found}
  def reset(service), do: Fuse.reset(service)

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
  def available?(service), do: Fuse.ask(service, :sync) == :ok

  @doc """
  Returns `true` if the service's circuit breaker is currently blown.

  A service that has not been started (see `start/2`) is _not_ considered blown;
  use `available?/1` if you want "ready to use" semantics that also account for
  services that were never started.
  """
  @spec blown?(service()) :: boolean()
  def blown?(service), do: Fuse.ask(service, :sync) == :blown

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
  Executes a function for the given service, handling retry and circuit breaker logic.

  `ExternalService.start/2` must be called for the service before using `call`.

  The provided function can indicate that a retry should be performed by returning the atom
  `:retry` or a tuple of the form `{:retry, reason}`, where `reason` is any arbitrary term. Any
  other result is considered successful, so the operation will not be retried and the result of
  the function will be returned as the result of `call`.

  Raised exceptions are only retried if their type is listed in the `:retry_on` retry option
  (which defaults to `[]`); otherwise they propagate to the caller.

  `retry_opts` may be a `t:ExternalService.RetryOptions.t/0` struct or a keyword list of retry
  options. When omitted (the two-argument form `call/2`), the default retry options configured for
  the service via `start/2` are used.
  """
  @spec call(service(), retriable_function()) :: error | (function_result :: any)
  def call(service, function) when is_function(function) do
    call(service, service_retry_options(service), function)
  end

  @spec call(service(), RetryOptions.t() | keyword(), retriable_function()) ::
          error | (function_result :: any)
  def call(service, retry_opts, function) do
    retry_opts = RetryOptions.new(retry_opts)

    call_span(service, fn ->
      case call_with_retry(service, retry_opts, function) do
        {:no_retry, result} -> result
        {:error, :retry} -> {:error, retries_exhausted(service, :reason_unknown)}
        {:error, {:retry, reason}} -> {:error, retries_exhausted(service, reason)}
        {:error, {:fuse_blown, service}} -> {:error, circuit_breaker_open(service)}
        {:error, {:fuse_not_found, service}} -> {:error, service_not_started(service)}
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
    retry_opts = RetryOptions.new(retry_opts)

    call_span(service, fn ->
      case call_with_retry(service, retry_opts, function) do
        {:no_retry, result} -> result
        {:error, :retry} -> raise retries_exhausted(service, :reason_unknown)
        {:error, {:retry, reason}} -> raise retries_exhausted(service, reason)
        {:error, {:fuse_blown, service}} -> raise circuit_breaker_open(service)
        {:error, {:fuse_not_found, service}} -> raise service_not_started(service)
      end
    end)
  end

  defp service_retry_options(service) do
    case State.fetch(service) do
      {:ok, %{retry_options: %RetryOptions{} = retry_options}} -> retry_options
      _ -> %RetryOptions{}
    end
  end

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
          | {:error, {:fuse_blown, service()}}
          | {:error, {:fuse_not_found, service()}}
  defp call_with_retry(service, retry_opts, function) do
    require Retry

    Retry.retry with: apply_retry_options(retry_opts), rescue_only: retry_opts.retry_on do
      case Fuse.ask(service, :sync) do
        :ok ->
          try_function(service, function)

        :blown ->
          emit_blown(service)
          throw(:blown)

        {:error, :not_found} ->
          throw(:not_found)
      end
    after
      {:no_retry, _} = result -> result
    else
      {:error, :retry} = error -> error
      {:error, {:retry, _reason}} = error -> error
      error -> raise(error)
    end
  catch
    :blown ->
      {:error, {:fuse_blown, service}}

    :not_found ->
      log_service_not_started(service)
      {:error, {:fuse_not_found, service}}
  end

  defp apply_retry_options(retry_opts) do
    import Retry.DelayStreams

    delay_stream =
      case retry_opts.backoff do
        :exponential -> exponential_backoff(retry_opts.base)
        :linear -> linear_backoff(retry_opts.base, retry_opts.factor)
      end

    delay_stream
    |> apply_jitter(retry_opts.jitter)
    |> apply_if(retry_opts.cap, &cap/2)
    |> apply_if(retry_opts.expiry, &expiry/2)
    |> apply_max_attempts(retry_opts.max_attempts)
  end

  # `jitter` accepts a boolean or an explicit proportion. Note that
  # `Retry.DelayStreams.randomize/2` expects a number, so a bare `true` must use
  # the arity-1 default rather than being passed through.
  defp apply_jitter(stream, proportion) when is_number(proportion),
    do: Retry.DelayStreams.randomize(stream, proportion)

  defp apply_jitter(stream, true), do: Retry.DelayStreams.randomize(stream)
  defp apply_jitter(stream, _falsy), do: stream

  defp apply_if(stream, nil, _fun), do: stream
  defp apply_if(stream, value, fun), do: fun.(stream, value)

  # `max_attempts` counts the initial attempt plus retries, so the delay stream
  # (one delay per retry) is limited to `max_attempts - 1` elements.
  defp apply_max_attempts(stream, nil), do: stream

  defp apply_max_attempts(stream, max_attempts)
       when is_integer(max_attempts) and max_attempts > 0,
       do: Stream.take(stream, max_attempts - 1)

  @spec try_function(service, retriable_function) ::
          {:error, {:retry, any}} | {:error, :retry} | {:no_retry, any} | no_return
  defp try_function(service, function) do
    rate_limit = State.get(service).rate_limit

    case RateLimit.call(rate_limit, function) do
      {:retry, reason} ->
        emit_retry(service, reason)
        Fuse.melt(service)
        {:error, {:retry, reason}}

      :retry ->
        emit_retry(service, :reason_unknown)
        Fuse.melt(service)
        {:error, :retry}

      result ->
        {:no_retry, result}
    end
  rescue
    error ->
      emit_retry(service, error)
      Fuse.melt(service)
      reraise error, __STACKTRACE__
  end

  defp retries_exhausted(service, reason) do
    # The retry reason can be any term, so it is carried in `:context` rather than
    # in Errata's `:reason` field (which is an atom classifier).
    Errata.create(RetriesExhausted, context: %{service: service, reason: reason})
  end

  defp circuit_breaker_open(service) do
    Errata.create(CircuitBreakerOpen, context: %{service: service})
  end

  defp service_not_started(service) do
    Errata.create(ServiceNotStarted, context: %{service: service})
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
          rate_limit: [limit: 100, per: :timer.seconds(1)],
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
    * `available?/0`, `blown?/0`, `reset/0`
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
        config = DeepMerge.deep_merge(@__external_service_opts__, overrides)

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

      @doc "Resets the circuit breaker. See `ExternalService.reset/1`."
      def reset, do: ExternalService.reset(@__external_service__)
    end
  end
end
