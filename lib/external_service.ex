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
      fails retriably: it returned `:retry` / `{:retry, reason}`, it returned a
      result matched by the `:retry_on` predicate, or it raised an exception matched
      by the `:retry_exceptions` retry option. Exceptions `:retry_exceptions` does
      not match neither count as a failure nor emit this event. Whether another
      attempt is actually made depends on the retry options.

      This counts **attempts**, under either `:melt` setting — a failed attempt is
      worth observing whether or not it charges the circuit breaker. It is
      therefore not a melt count: with the default `melt: :per_call`, a call that
      retries four times and then succeeds emits this four times and melts nothing.
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

    * `[:external_service, :concurrency, :rejected]` - emitted when a call is
      shed because the service's concurrency limit was fully in use.
      * Measurements: `:limit`, `:wait_time` (milliseconds spent waiting, `0`
        unless a `:wait` budget is configured)
      * Metadata: `:service`

    * `[:external_service, :concurrency, :waited]` - emitted when a call had to
      wait for a slot but got one before its `:wait` budget ran out. Calls served
      without waiting emit nothing.
      * Measurements: `:limit`, `:wait_time` (milliseconds waited)
      * Metadata: `:service`
  """

  alias ExternalService.CircuitBreaker
  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.Concurrency
  alias ExternalService.ConfigCheck
  alias ExternalService.Explanation
  alias ExternalService.RateLimited
  alias ExternalService.RateLimiter
  alias ExternalService.RetriesExhausted
  alias ExternalService.Retry
  alias ExternalService.RetryOptions
  alias ExternalService.ServiceNotStarted
  alias ExternalService.ServiceSaturated
  alias ExternalService.Simulation
  alias ExternalService.Simulator

  require Errata
  require Logger

  @typedoc "A term that uniquely identifies an external service."
  @type service :: term()

  @typedoc """
  A dependency to simulate a configuration against. See `simulate/3`.
  """
  @type scenario ::
          :always_failing
          | {:always_failing, attempt_ms :: non_neg_integer()}
          | {:slow, attempt_ms :: non_neg_integer()}
          | {:failing_for, ms :: non_neg_integer()}
          | {:intermittent, rate :: float()}

  @typedoc """
  What one unit of the circuit breaker's `:tolerate` counts: a failing call, or a
  failing attempt. See the `:melt` circuit breaker option under `start/2`.
  """
  @type melt :: :per_call | :per_attempt

  @typedoc "Error returned when the allowable number of retries has been exceeded"
  @type retries_exhausted :: {:error, RetriesExhausted.t()}

  @typedoc "Error returned when a service's circuit breaker is open"
  @type circuit_breaker_open :: {:error, CircuitBreakerOpen.t()}

  @typedoc "Error returned when a service has not been started with `ExternalService.start/2`"
  @type service_not_started :: {:error, ServiceNotStarted.t()}

  @typedoc "Error returned when a call is throttled beyond the rate limit `:wait` budget"
  @type rate_limited :: {:error, RateLimited.t()}

  @typedoc "Error returned when a call is shed because the concurrency limit was full"
  @type service_saturated :: {:error, ServiceSaturated.t()}

  @typedoc "Union type representing all the possible error return values"
  @type error ::
          retries_exhausted
          | circuit_breaker_open
          | service_not_started
          | rate_limited
          | service_saturated

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
        "Number of failures tolerated within the `:within` window before the breaker " <>
          "opens. What counts as one failure is set by `:melt`, and defaults to one " <>
          "failing **call** — so `tolerate: 3` means three dead calls, whatever " <>
          "`:max_attempts` is. `:infinity` installs no breaker at all: it never opens, " <>
          "holds no state, and cannot be combined with `:fault_injection`."
    ],
    melt: [
      type: {:in, [:per_call, :per_attempt]},
      default: :per_call,
      doc:
        "What one unit of `:tolerate` counts. `:per_call` (the default) melts the breaker " <>
          "once per call, when its retrying gives up, so `:tolerate` is denominated in " <>
          "calls and is independent of `:max_attempts`. `:per_attempt` melts on every " <>
          "failing attempt, which is how versions before 3.0 behaved: a single call with " <>
          "`max_attempts: 5` then contributes up to 5, and `:tolerate` cannot be tuned " <>
          "independently of the retry options. `:per_call` requires retrying to be " <>
          "bounded — see the note on unbounded retries below."
    ],
    within: [
      type: {:or, [:pos_integer, {:in, [:auto]}]},
      default: :auto,
      doc:
        "Length of the failure-counting window, in milliseconds. `:auto` (the default) " <>
          "sizes the window against the retry options instead, since how long it takes " <>
          "`:tolerate` failures to arrive depends on how long a failing call takes. It is " <>
          "a floor, never narrower than the 10 seconds it replaces — see " <>
          "[Sizing the breaker](tuning.md) for when to set it yourself."
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

  @doc false
  # The raw option schemas, for tests that derive generators from them rather than
  # restating them. Exposed so that an option added to one is covered by the
  # property suite without anyone remembering to extend a matrix.
  @spec __schema__(:start | :circuit_breaker | :rate_limit | :concurrency) :: keyword()
  def __schema__(:start), do: @start_schema
  def __schema__(:circuit_breaker), do: @circuit_breaker_schema
  def __schema__(:rate_limit), do: @rate_limit_schema
  def __schema__(:concurrency), do: @concurrency_schema

  defmodule State do
    @moduledoc false

    # Per-service configuration is stored in `:persistent_term`. The state for a
    # service is written once by `ExternalService.start/2` and read on every call,
    # which is exactly the access pattern `:persistent_term` is optimized for:
    # lock-free reads with no process to message or crash. This replaces the
    # previous unsupervised `Agent`.

    defstruct [
      :service,
      :circuit_breaker,
      :melt,
      :rate_limit,
      :concurrency,
      :retry_options,
      :sleep,
      :options
    ]

    @type t :: %__MODULE__{
            service: ExternalService.service(),
            circuit_breaker: ExternalService.CircuitBreaker.t(),
            melt: ExternalService.melt(),
            rate_limit: ExternalService.RateLimiter.t(),
            concurrency: ExternalService.Concurrency.t(),
            retry_options: ExternalService.RetryOptions.t(),
            sleep: ExternalService.sleep_function(),
            # The options this service was actually started with, after validation
            # and after `:within` has been resolved — what `ExternalService.explain/1`
            # reports, and the only backend-agnostic record of them. A breaker
            # backend's config is opaque by design, so `:tolerate` cannot be read
            # back out of it.
            options: keyword()
          }

    def put(%__MODULE__{service: service} = state) do
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

  ## Configuration checks

  These options are validated individually, and then checked *against each other* —
  because the mistakes worth catching are pairs of options that are each valid and
  jointly wrong. A window narrower than the failures it has to count, or ten
  attempts of uncapped exponential backoff, produce a warning naming the setting to
  change and a value to try.

  Services declared with `use ExternalService` are checked **at compile time**, so
  the warning carries a file and a line and fails a build compiled with
  `--warnings-as-errors`. Services started through this function are checked here,
  which is also what covers child-spec overrides, since those are runtime values.

  Combinations that cannot work at all — rather than merely being unwise — raise
  instead. Set how findings are reported with:

      config :external_service, on_suspicious_config: :warn   # | :raise | :ignore

  `:warn` is the default. `:raise` is worth setting in a test environment, where a
  suspicious configuration is better as a failure than as a log line. `:ignore` is
  for a configuration you have decided is right despite what the checks make of it.

  ## Options

  #{NimbleOptions.docs(@start_schema)}
  """
  @spec start(service(), options()) :: :ok
  def start(service, options \\ []) do
    options = validate!(service, options)
    validate_breaker_combination!(service, options[:circuit_breaker])

    # After the raises, which reject configurations that cannot work, and before
    # anything is installed. These are configurations that work and are probably
    # not what was meant — child-spec overrides are runtime values, so this is the
    # only place that sees what a service is finally started with.
    ConfigCheck.report(service, options)

    options = resolve_breaker_options(service, options)
    {melt, breaker_options} = Keyword.pop!(options[:circuit_breaker], :melt)

    circuit_breaker = CircuitBreaker.install(service, breaker_options)

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

    State.put(%State{
      service: service,
      circuit_breaker: circuit_breaker,
      melt: melt,
      rate_limit: rate_limit,
      concurrency: concurrency,
      retry_options: retry_options,
      sleep: sleep,
      options: options
    })

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

  # Everything that turns written options into the options a service actually runs
  # with: the bound `:per_call` requires, and `:within` when it sizes itself.
  # Shared with `explain/1`, so that a report describes the numbers that would be
  # installed rather than the symbols that were written.
  defp resolve_breaker_options(service, options) do
    {melt, breaker_options} = Keyword.pop!(options[:circuit_breaker], :melt)
    validate_melt_bound!(service, melt, options[:retry])

    breaker_options =
      breaker_options
      |> resolve_within(melt, options[:retry])
      |> Keyword.put(:melt, melt)

    Keyword.put(options, :circuit_breaker, breaker_options)
  end

  # `:within` has to be wide enough for `:tolerate` failures to land inside it, and
  # how long that takes depends on the retry options — which is why a flat default
  # stops fitting the moment someone raises `:base`. `:auto` reads it off them; the
  # rule itself lives in `CircuitBreaker.auto_window/3`, which the configuration
  # checks share so that a warning suggests what `:auto` would have installed.
  defp resolve_within(breaker_options, melt, retry_options) do
    Keyword.update!(breaker_options, :within, fn
      :auto ->
        CircuitBreaker.auto_window(
          breaker_options[:tolerate],
          melt,
          RetryOptions.new(retry_options)
        )

      within ->
        within
    end)
  end

  # Per-call melting charges the breaker once, when a call's retrying gives up. A
  # call that cannot give up therefore never melts at all, and the breaker — which
  # used to be the backstop that stopped such a call — records nothing about it.
  # Worse than useless: before 3.0 an unbounded retry loop was eventually halted by
  # the breaker it was melting, so allowing this combination silently would turn a
  # bounded-in-practice loop into one that runs forever.
  #
  # So `:per_call` requires retrying to be bounded by something. Either bound will
  # do — a count or a time budget — and this is the combination `guides/tuning.md`
  # already told people to avoid, now that it is not merely unwise but inert.
  #
  # Checked here for the service's configured defaults, and again per call in
  # `call_with_retry/4`, because retry options can be overridden per call and an
  # override can remove the bound this checked.
  @doc false
  @spec validate_melt_bound!(service(), melt(), RetryOptions.t() | keyword()) :: :ok
  def validate_melt_bound!(service, melt, retry_options)

  def validate_melt_bound!(_service, :per_attempt, _retry_options), do: :ok

  def validate_melt_bound!(service, :per_call, retry_options) do
    retry_options = RetryOptions.new(retry_options)

    if RetryOptions.window(retry_options) == :infinity do
      raise ArgumentError, """
      #{inspect(service)} combines circuit_breaker: [melt: :per_call] with retry \
      options that never give up (max_attempts: :infinity and no :expiry), which \
      cannot work: :per_call melts the breaker when a call's retrying gives up, so \
      a call that never gives up never melts, and nothing stops it.

      Bound the retrying, with either bound:

          retry: [max_attempts: :infinity, expiry: :timer.seconds(30)]
          retry: [max_attempts: 5]

      Or keep the pre-3.0 melt semantics, where every failing attempt melts the \
      breaker and the breaker is what eventually halts an unbounded retry loop:

          circuit_breaker: [melt: :per_attempt]
      """
    end

    :ok
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
  Describes what a configuration will do, as a report meant to be read.

      IO.puts ExternalService.explain(MyApp.Stripe)

  Takes either a started service or a keyword list of options, so a configuration
  can be examined before it ships as well as after:

      IO.puts ExternalService.explain(
        circuit_breaker: [tolerate: 3],
        retry: [base: 100, max_attempts: 5]
      )

  Everything in the report is derived from the options rather than measured, and
  the checks described above are included in it, so this is also the way to see why
  a service warned at compile time.

  ## Example

      :payments

        retry
          window       1.5s
          delays       100ms, 200ms, 400ms, 800ms
          attempts     up to 5
          time budget  none (:expiry unset)

        circuit breaker
          opens after      4 failing calls
          counting window  10s
          resets after     60s
          backend          ExternalService.CircuitBreaker.Fuse

        rate limit
          none  calls are not throttled

        concurrency
          none  calls are not limited in flight

        a fully-failing call
          spends  1.5s waiting between attempts
          plus    however long its 5 attempts take — nothing here bounds a single attempt

  Note that a keyword list is always read as options. A service identified by a
  list has to be explained through the started-service path, which means starting
  it first.
  """
  @spec explain(service() | keyword()) :: String.t()
  def explain(service_or_options)

  def explain(options) when is_list(options) do
    service = Keyword.get(options, :name, "this configuration")

    options
    |> Keyword.delete(:name)
    |> then(&validate!(service, &1))
    |> then(&resolve_breaker_options(service, &1))
    |> then(&Explanation.render(service, &1))
  end

  def explain(service) do
    case State.fetch(service) do
      {:ok, %State{options: options}} -> Explanation.render(service, options)
      :error -> service_not_started_message(service)
    end
  end

  @doc """
  Runs a configuration against a failing dependency and reports what happened.

  `explain/1` says what a configuration *is*; this says what it *does*. The
  question it answers is the one every resilience configuration has and few are
  ever asked: does the breaker actually open, how long does a failing call take,
  and how much load does a dead dependency absorb first?

      test "our breaker actually opens, and fast enough" do
        assert %ExternalService.Simulation{opens_after: opens, worst_call: worst} =
                 ExternalService.simulate(MyApp.Stripe, :always_failing)

        assert opens <= 5
        assert worst < 2_000
      end

  Takes a started service or a keyword list of options, like `explain/1`.

  ## Scenarios

    * `:always_failing` — every attempt fails, instantly. The base case.
    * `{:always_failing, attempt_ms}` — every attempt fails and takes `attempt_ms`.
      Attempt duration is the one thing a configuration cannot state, and the thing
      that makes a hand-sized `:within` too narrow, so this is the scenario worth
      running against a dependency you know to be slow.
    * `{:slow, attempt_ms}` — attempts succeed but take `attempt_ms` each. Nothing
      fails, so the breaker never opens; `:worst_call` is the answer here.
    * `{:failing_for, ms}` — fails for the first `ms` of simulated time, then
      recovers.
    * `{:intermittent, rate}` — each attempt fails with probability `rate`. Seed
      `:rand` for a reproducible run.

  ## Options

    * `:max_calls` — how many calls to simulate before giving up on the breaker
      opening. Defaults to `100`.

  ## What it does and does not model

  It runs on a **virtual clock**, so simulating half an hour of a background job
  costs microseconds and no test waits for anything. Delays are nominal, with
  `:jitter` switched off — the same choice `RetryOptions.window/1` and `explain/1`
  make, so that all three agree and a simulation asserted in a test does not vary
  between runs. Jitter changes the exact `:worst_call`, never whether a breaker
  opens.

  The delays come from the library's own planner, the options are resolved through
  the same path `start/2` uses, and melting follows the service's `:melt` setting.
  The one thing modelled rather than executed is the circuit breaker's sliding
  failure window, which is what makes a virtual clock possible at all — a real
  breaker counts against real time. That model is pinned against measured behavior
  in the test suite, including a configuration that stays closed through twelve
  consecutive failing calls.

  The rate limiter and the concurrency limit are not simulated. Neither melts the
  breaker, and both govern the traffic reaching a service rather than what the
  service does with a failure.

  Simulated calls arrive one after another, which is the worst case for opening a
  breaker: concurrent callers deliver failures closer together, so a breaker that
  opens here opens at least as readily under real traffic.

  ## Examples

      iex> %ExternalService.Simulation{opens_after: opens} =
      ...>   ExternalService.simulate(
      ...>     [circuit_breaker: [tolerate: 3], retry: [base: 100, max_attempts: 5]],
      ...>     :always_failing
      ...>   )
      iex> opens
      4
  """
  @spec simulate(service() | keyword(), scenario(), keyword()) :: Simulation.t()
  def simulate(service_or_options, scenario, opts \\ [])

  def simulate(options, scenario, opts) when is_list(options) do
    service = Keyword.get(options, :name, "this configuration")

    resolved =
      options
      |> Keyword.delete(:name)
      |> then(&validate!(service, &1))
      |> then(&resolve_breaker_options(service, &1))

    Simulator.run(service, resolved, scenario, opts)
  end

  def simulate(service, scenario, opts) do
    case State.fetch(service) do
      {:ok, %State{options: options}} ->
        Simulator.run(service, options, scenario, opts)

      # Unlike `explain/1`, which can report "not started" as part of a string,
      # there is no simulation to return for a service that does not exist.
      :error ->
        raise service_not_started(service)
    end
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
    # Retry options can be overridden per call, and an override can remove the
    # bound that `start/2` checked for.
    :ok = validate_melt_bound!(service, state.melt, retry_opts)

    attempt = fn ->
      case CircuitBreaker.ask(service, state.circuit_breaker) do
        :ok ->
          try_function(service, state, retry_opts, function)

        :blown ->
          emit_blown(service)
          throw(:blown)
      end
    end

    case Retry.call(retry_opts, state.sleep, attempt) do
      {:no_retry, _} = result ->
        result

      # The retrying gave up. Under the default `:per_call` melt semantics this is
      # the one moment a failing call charges the circuit breaker, which is what
      # makes `:tolerate` count calls rather than attempts. A call that succeeds on
      # a later attempt never reaches here and so never melts: retries did their
      # job, and a breaker that opened on it would turn working calls into errors.
      {:error, :retry} = error ->
        melt_call(service, state)
        error

      {:error, {:retry, _reason}} = error ->
        melt_call(service, state)
        error

      # Retries are spent on an exception we were retrying: re-raise the original
      # with its original stacktrace, so the trace still points at the code that
      # raised rather than at this retry loop.
      {:error, {:retry_exception, exception, stacktrace}} ->
        melt_call(service, state)
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
    #
    # Both limits are checked *around* the attempt rather than inside it, because
    # neither produces something to retry: the wrapped function never ran. They
    # are thrown rather than returned so that they escape the retry loop instead
    # of being treated as a result to classify.
    in_flight = fn -> Concurrency.call(state.concurrency, function) end

    guarded = fn ->
      case RateLimiter.call(state.rate_limit, in_flight) do
        {Concurrency, :saturated} -> throw(:saturated)
        {RateLimiter, :rate_limited, retry_after} -> throw({:rate_limited, retry_after})
        result -> result
      end
    end

    service
    |> Retry.attempt(retry_opts, guarded)
    |> record_attempt(service, state)
  end

  # What a retriable failure costs the service. `Retry` decides *whether* an
  # attempt wants another; this is where that decision is charged to the circuit
  # breaker and reported to telemetry, because both are about composing mechanisms
  # rather than about retrying.
  #
  # Telemetry is emitted per attempt under both melt semantics — an attempt that
  # failed is worth observing whether or not it charges the breaker — so
  # `[:external_service, :call, :retry]` counts attempts and is not a melt count.
  defp record_attempt({:no_retry, _} = result, _service, _state), do: result

  defp record_attempt(retry, service, state) do
    emit_retry(service, Retry.reason(retry))
    if state.melt == :per_attempt, do: melt(service, state)
    retry
  end

  # Melting for the call as a whole, under `:per_call`. Split from `melt/2` so
  # that each melt site names which semantics put it there.
  defp melt_call(service, %State{melt: :per_call} = state), do: melt(service, state)
  defp melt_call(_service, %State{melt: :per_attempt}), do: :ok

  defp melt(service, state), do: CircuitBreaker.melt(service, state.circuit_breaker)

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

  @doc false
  defmacro __before_compile__(env) do
    service = Module.get_attribute(env.module, :__external_service__)
    options = Module.get_attribute(env.module, :__external_service_opts__)

    case {ConfigCheck.reporting(), ConfigCheck.run(service, options)} do
      {:ignore, _findings} ->
        :ok

      {_reporting, []} ->
        :ok

      {:raise, findings} ->
        raise ArgumentError, Enum.map_join(findings, "\n\n", & &1.message)

      {:warn, findings} ->
        # `IO.warn/2` with an env gives the warning a file and a line, so it reads
        # like any other compiler warning and fails a build compiled with
        # `--warnings-as-errors`. It anchors at the `use ExternalService` call,
        # captured in `__using__/1`, rather than at this hook's `defmodule` — the
        # options are written at the `use`, and a file holding several services
        # would otherwise point every warning at the same line.
        Enum.each(findings, &IO.warn(&1.message, warning_env(env)))
    end

    nil
  end

  # The `use` position when `__using__/1` recorded one; this hook's own env
  # otherwise, so a module that sets `@before_compile ExternalService` by hand
  # still gets a warning anchored somewhere real.
  defp warning_env(env) do
    case Module.get_attribute(env.module, :__external_service_use_position__) do
      {file, line} when is_binary(file) and is_integer(line) -> %{env | file: file, line: line}
      _ -> env
    end
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
  `:concurrency`, `:retry`, `:sleep_function`), plus:

    * `:name` - the term that identifies the service. Defaults to the module name.

  ## Generated functions

    * `call/1`, `call/2`, `call!/1`, `call!/2`
    * `call_async/1`, `call_async/2`
    * `call_async_stream/2`, `call_async_stream/3`, `call_async_stream/4`
    * `available?/0`, `blown?/0`, `saturated?/0`, `reset/0`, `reset_all/0`
    * `child_spec/1`, `start_link/1`
  """
  defmacro __using__(opts) do
    # `__CALLER__` is the `use ExternalService` call itself, which is where the
    # options being checked are written. The `@before_compile` env is the
    # `defmodule`, so the position has to be captured here and carried across.
    use_position = {__CALLER__.file, __CALLER__.line}

    quote bind_quoted: [opts: opts, use_position: use_position] do
      @__external_service__ Keyword.get(opts, :name, __MODULE__)
      @__external_service_opts__ Keyword.delete(opts, :name)
      @__external_service_use_position__ use_position

      # Checked from a `@before_compile` hook rather than here, because `__using__`
      # receives the options as AST: `within: :timer.seconds(1)` has not been
      # evaluated yet. By the time the hook runs, the module attribute holds real
      # values.
      @before_compile ExternalService

      @doc false
      def child_spec(overrides \\ []) do
        %{id: __MODULE__, type: :worker, start: {__MODULE__, :start_link, [overrides]}}
      end

      @doc """
      Starts the service (installing its circuit breaker, rate limiter, and
      concurrency limit, if configured) linked to the current process.

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

      @doc "Resets the circuit breaker, the rate limiter, and the concurrency limit. See `ExternalService.reset_all/1`."
      def reset_all, do: ExternalService.reset_all(@__external_service__)
    end
  end
end
