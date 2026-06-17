defmodule ExternalService do
  @moduledoc """
  ExternalService handles all retry and circuit breaker logic for calls to external services.

  ## Telemetry

  `ExternalService` emits [`:telemetry`](https://hexdocs.pm/telemetry) events so
  that calls to external services can be observed and instrumented. Attach a
  handler to any of the events below to forward them to your metrics or logging
  backend.

  All events carry a `:service` key in their metadata, which is the fuse name of
  the service the event relates to.

    * `[:external_service, :call, :start]` - emitted when a guarded call begins.
      * Measurements: `:system_time`, `:monotonic_time`
      * Metadata: `:service`

    * `[:external_service, :call, :stop]` - emitted when a guarded call completes
      (including when it returns an error tuple such as `retries_exhausted` or
      `fuse_blown`).
      * Measurements: `:duration`, `:monotonic_time`
      * Metadata: `:service`, `:result` (the value returned from the call)

    * `[:external_service, :call, :exception]` - emitted when a guarded call
      raises (for example a non-retriable exception, or `call!/3` raising on a
      blown fuse or exhausted retries).
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

  @typedoc "Name of a fuse"
  @type fuse_name :: term()

  @typedoc "Error returned when the allowable number of retries has been exceeded"
  @type retries_exhausted :: {:error, RetriesExhausted.t()}

  @typedoc "Error returned when a service's circuit breaker is open (the fuse is blown)"
  @type circuit_breaker_open :: {:error, CircuitBreakerOpen.t()}

  @typedoc "Error returned when a service has not been started with `ExternalService.start/2`"
  @type service_not_started :: {:error, ServiceNotStarted.t()}

  @typedoc "Union type representing all the possible error return values"
  @type error :: retries_exhausted | circuit_breaker_open | service_not_started

  @type retriable_function_result ::
          :retry | {:retry, reason :: any()} | (function_result :: any())

  @type retriable_function :: (-> retriable_function_result())

  @typedoc """
  Strategy controlling fuse behavior.
  """
  @type fuse_strategy ::
          {:standard, max_melt_attempts :: pos_integer(), time_window :: pos_integer()}
          | {:fault_injection, rate :: float(), max_melt_attempts :: pos_integer(),
             time_window :: pos_integer()}

  @typedoc """
  A tuple specifying rate-limiting behavior.

  The first element of the tuple is the number of calls to allow in a given time window.
  The second element is the time window in milliseconds.
  """
  @type rate_limit :: {limit :: pos_integer(), time_window :: pos_integer()}

  @typedoc """
  The sleep function to be called when reaching the configured rate limit quota.

  In some situations, like tests, blocking the process for an extended period of
  time can be undesired. In these cases this function can be changed. Defaults
  to `Process.sleep/1`.
  """
  @type sleep_function :: (number -> any)

  @typedoc """
  Options used for controlling circuit breaker and rate-limiting behavior.

  See the [fuse docs](https://hexdocs.pm/fuse/) for further information about available fuse options.
  """
  @type options :: [
          fuse_strategy: fuse_strategy(),
          fuse_refresh: pos_integer(),
          rate_limit: rate_limit(),
          sleep_function: sleep_function()
        ]

  @default_fuse_options %{
    fuse_strategy: {:standard, 10, 10_000},
    fuse_refresh: 60_000
  }

  defmodule State do
    @moduledoc false

    # Per-service configuration is stored in `:persistent_term`. The state for a
    # service is written once by `ExternalService.start/2` and read on every call,
    # which is exactly the access pattern `:persistent_term` is optimized for:
    # lock-free reads with no process to message or crash. This replaces the
    # previous unsupervised `Agent`.

    defstruct [:fuse_name, :fuse_options, :rate_limit]

    def init(fuse_name, fuse_options, rate_limit) do
      state = %__MODULE__{
        fuse_name: fuse_name,
        fuse_options: fuse_options,
        rate_limit: rate_limit
      }

      :persistent_term.put(key(fuse_name), state)
      state
    end

    def get(fuse_name), do: :persistent_term.get(key(fuse_name))

    def delete(fuse_name), do: :persistent_term.erase(key(fuse_name))

    defp key(fuse_name), do: {__MODULE__, fuse_name}
  end

  @doc """
  Initializes a new fuse for a specific service.

  The `fuse_name` is a term that uniquely identifies an external service within the scope of
  an application.

  The `options` argument allows for controlling the circuit breaker behavior and rate-limiting
  behavior when making calls to the external service. See `t:options/0` for details.
  """
  @spec start(fuse_name(), options()) :: :ok
  def start(fuse_name, options \\ []) do
    fuse_opts = {
      Keyword.get(options, :fuse_strategy, @default_fuse_options.fuse_strategy),
      {:reset, Keyword.get(options, :fuse_refresh, @default_fuse_options.fuse_refresh)}
    }

    :ok = Fuse.install(fuse_name, fuse_opts)
    rate_limit = RateLimit.new(fuse_name, Keyword.get(options, :rate_limit), options)
    State.init(fuse_name, fuse_opts, rate_limit)
    :ok
  end

  @doc """
  Stops the fuse for a specific service.

  Stopping is idempotent: it is safe to call on a service that was never started
  or has already been stopped.
  """
  @spec stop(fuse_name()) :: :ok
  def stop(fuse_name) do
    # `:fuse.remove/1` returns `{:error, :not_found}` for an unknown fuse; treat
    # that as success so that stop/1 is idempotent.
    _ = Fuse.remove(fuse_name)
    State.delete(fuse_name)
    :ok
  end

  @doc """
  Resets the given fuse.

  After reset, the fuse will be unbroken with no melts.
  """
  @spec reset_fuse(fuse_name()) :: :ok | {:error, :not_found}
  def reset_fuse(fuse_name), do: Fuse.reset(fuse_name)

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
  @spec available?(fuse_name()) :: boolean()
  def available?(fuse_name), do: Fuse.ask(fuse_name, :sync) == :ok

  @doc """
  Returns `true` if the service's circuit breaker is currently blown.

  A service that has not been started (see `start/2`) is _not_ considered blown;
  use `available?/1` if you want "ready to use" semantics that also account for
  services that were never started.
  """
  @spec blown?(fuse_name()) :: boolean()
  def blown?(fuse_name), do: Fuse.ask(fuse_name, :sync) == :blown

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
  @spec all_available?([fuse_name()]) :: boolean()
  def all_available?(fuse_names), do: Enum.all?(fuse_names, &available?/1)

  @doc """
  Given a fuse name and retry options execute a function handling any retry and circuit breaker
  logic.

  `ExternalService.start` must be run with the fuse name before using call.

  The provided function can indicate that a retry should be performed by returning the atom
  `:retry` or a tuple of the form `{:retry, reason}`, where `reason` is any arbitrary term, or by
  raising a `RuntimeError`. Any other result is considered successful so the operation will not be
  retried and the result of the function will be returned as the result of `call`.
  """
  @spec call(fuse_name(), RetryOptions.t(), retriable_function()) ::
          error | (function_result :: any)
  def call(fuse_name, retry_opts \\ %RetryOptions{}, function) do
    call_span(fuse_name, fn ->
      case call_with_retry(fuse_name, retry_opts, function) do
        {:no_retry, result} -> result
        {:error, :retry} -> {:error, retries_exhausted(fuse_name, :reason_unknown)}
        {:error, {:retry, reason}} -> {:error, retries_exhausted(fuse_name, reason)}
        {:error, {:fuse_blown, fuse_name}} -> {:error, circuit_breaker_open(fuse_name)}
        {:error, {:fuse_not_found, fuse_name}} -> {:error, service_not_started(fuse_name)}
      end
    end)
  end

  @doc """
  Like `call/3`, but raises an exception if retries are exhausted or the fuse is blown.
  """
  @spec call!(fuse_name(), RetryOptions.t(), retriable_function()) ::
          function_result :: any | no_return
  def call!(fuse_name, retry_opts \\ %RetryOptions{}, function) do
    call_span(fuse_name, fn ->
      case call_with_retry(fuse_name, retry_opts, function) do
        {:no_retry, result} -> result
        {:error, :retry} -> raise retries_exhausted(fuse_name, :reason_unknown)
        {:error, {:retry, reason}} -> raise retries_exhausted(fuse_name, reason)
        {:error, {:fuse_blown, fuse_name}} -> raise circuit_breaker_open(fuse_name)
        {:error, {:fuse_not_found, fuse_name}} -> raise service_not_started(fuse_name)
      end
    end)
  end

  @doc """
  Asynchronous version of `ExternalService.call`.

  Returns a `Task` that may be used to retrieve the result of the async call.
  """
  @spec call_async(fuse_name(), RetryOptions.t(), retriable_function()) :: Task.t()
  def call_async(fuse_name, retry_opts \\ %RetryOptions{}, function) do
    Task.async(fn -> call(fuse_name, retry_opts, function) end)
  end

  @doc """
  Parallel, streaming version of `ExternalService.call`.

  See `call_async_stream/5` for full documentation.
  """
  @spec call_async_stream(Enumerable.t(), fuse_name(), (any() -> retriable_function_result())) ::
          Enumerable.t()
  def call_async_stream(enumerable, fuse_name, function) when is_function(function),
    do: call_async_stream(enumerable, fuse_name, %RetryOptions{}, [], function)

  @doc """
  Parallel, streaming version of `ExternalService.call`.

  See `call_async_stream/5` for full documentation.
  """
  @spec call_async_stream(
          Enumerable.t(),
          fuse_name(),
          RetryOptions.t() | (async_opts :: list()),
          (any() -> retriable_function_result())
        ) :: Enumerable.t()
  def call_async_stream(enumerable, fuse_name, retry_opts_or_async_opts, function)

  def call_async_stream(enumerable, fuse_name, retry_opts = %RetryOptions{}, function)
      when is_function(function),
      do: call_async_stream(enumerable, fuse_name, retry_opts, [], function)

  def call_async_stream(enumerable, fuse_name, async_opts, function)
      when is_list(async_opts) and is_function(function),
      do: call_async_stream(enumerable, fuse_name, %RetryOptions{}, async_opts, function)

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
          fuse_name(),
          RetryOptions.t(),
          async_opts :: list(),
          (any() -> retriable_function_result())
        ) :: Enumerable.t()
  def call_async_stream(enumerable, fuse_name, retry_opts = %RetryOptions{}, async_opts, function)
      when is_list(async_opts) and is_function(function) do
    fun = fn item ->
      call(fuse_name, retry_opts, fn -> function.(item) end)
    end

    Task.async_stream(enumerable, fun, async_opts)
  end

  @spec call_with_retry(fuse_name(), RetryOptions.t(), retriable_function()) ::
          {:no_retry, function_result :: any()}
          | {:error, :retry}
          | {:error, {:retry, reason :: any()}}
          | {:error, {:fuse_blown, fuse_name()}}
          | {:error, {:fuse_not_found, fuse_name()}}
  defp call_with_retry(fuse_name, retry_opts, function) do
    require Retry

    Retry.retry with: apply_retry_options(retry_opts), rescue_only: retry_opts.rescue_only do
      case Fuse.ask(fuse_name, :sync) do
        :ok ->
          try_function(fuse_name, function)

        :blown ->
          emit_blown(fuse_name)
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
      {:error, {:fuse_blown, fuse_name}}

    :not_found ->
      log_fuse_not_found(fuse_name)
      {:error, {:fuse_not_found, fuse_name}}
  end

  defp apply_retry_options(retry_opts) do
    import Retry.DelayStreams

    delay_stream =
      case retry_opts.backoff do
        {:exponential, initial_delay} -> exponential_backoff(initial_delay)
        {:linear, initial_delay, factor} -> linear_backoff(initial_delay, factor)
      end

    delay_stream
    |> apply_randomize(retry_opts.randomize)
    |> apply_if(retry_opts.cap, &cap/2)
    |> apply_if(retry_opts.expiry, &expiry/2)
    |> apply_max_attempts(retry_opts.max_attempts)
  end

  # `randomize` accepts a boolean or an explicit jitter proportion. Note that
  # `Retry.DelayStreams.randomize/2` expects a number, so a bare `true` must use
  # the arity-1 default rather than being passed through.
  defp apply_randomize(stream, proportion) when is_number(proportion),
    do: Retry.DelayStreams.randomize(stream, proportion)

  defp apply_randomize(stream, true), do: Retry.DelayStreams.randomize(stream)
  defp apply_randomize(stream, _falsy), do: stream

  defp apply_if(stream, nil, _fun), do: stream
  defp apply_if(stream, value, fun), do: fun.(stream, value)

  # `max_attempts` counts the initial attempt plus retries, so the delay stream
  # (one delay per retry) is limited to `max_attempts - 1` elements.
  defp apply_max_attempts(stream, nil), do: stream

  defp apply_max_attempts(stream, max_attempts)
       when is_integer(max_attempts) and max_attempts > 0,
       do: Stream.take(stream, max_attempts - 1)

  @spec try_function(fuse_name, retriable_function) ::
          {:error, {:retry, any}} | {:error, :retry} | {:no_retry, any} | no_return
  defp try_function(fuse_name, function) do
    rate_limit = State.get(fuse_name).rate_limit

    case RateLimit.call(rate_limit, function) do
      {:retry, reason} ->
        emit_retry(fuse_name, reason)
        Fuse.melt(fuse_name)
        {:error, {:retry, reason}}

      :retry ->
        emit_retry(fuse_name, :reason_unknown)
        Fuse.melt(fuse_name)
        {:error, :retry}

      result ->
        {:no_retry, result}
    end
  rescue
    error ->
      emit_retry(fuse_name, error)
      Fuse.melt(fuse_name)
      reraise error, __STACKTRACE__
  end

  defp retries_exhausted(fuse_name, reason) do
    # The retry reason can be any term, so it is carried in `:context` rather than
    # in Errata's `:reason` field (which is an atom classifier).
    Errata.create(RetriesExhausted, context: %{service: fuse_name, reason: reason})
  end

  defp circuit_breaker_open(fuse_name) do
    Errata.create(CircuitBreakerOpen, context: %{service: fuse_name})
  end

  defp service_not_started(fuse_name) do
    Errata.create(ServiceNotStarted, context: %{service: fuse_name})
  end

  defp call_span(fuse_name, fun) do
    :telemetry.span([:external_service, :call], %{service: fuse_name}, fn ->
      result = fun.()
      {result, %{service: fuse_name, result: result}}
    end)
  end

  defp emit_retry(fuse_name, reason) do
    :telemetry.execute(
      [:external_service, :call, :retry],
      %{count: 1},
      %{service: fuse_name, reason: reason}
    )
  end

  defp emit_blown(fuse_name) do
    :telemetry.execute(
      [:external_service, :circuit_breaker, :blown],
      %{count: 1},
      %{service: fuse_name}
    )
  end

  defp log_fuse_not_found(fuse_name) do
    Logger.error(fuse_not_found_message(fuse_name))
  end

  defp fuse_not_found_message(fuse_name) do
    fuse_name = inspect(fuse_name)

    "Fuse :#{fuse_name} not found. To initialize this fuse, call " <>
      "ExternalService.start(:#{fuse_name}) in your application start code."
  end
end
