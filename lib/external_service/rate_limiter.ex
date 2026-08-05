defmodule ExternalService.RateLimiter do
  @moduledoc """
  The behaviour implemented by rate limiter backends.

  A service's limiter is chosen with the `:backend` rate limit option, and
  defaults to `ExternalService.RateLimiter.Local`. `ExternalService.RateLimiter.Hammer`
  meters against a [Hammer](https://hexdocs.pm/hammer) module, which is the
  supported route to a limit shared across a cluster.

  ## Writing a backend

  A backend answers one question, in two forms: may a call proceed right now,
  and if not, how long until it may? `c:check/2` answers it and consumes the
  call; `c:peek/2` answers it and consumes nothing. Everything else — sleeping,
  honoring the `:wait` budget, telemetry, logging — is handled for you, so that
  every backend behaves consistently.

      defmodule MyApp.RateLimiter do
        @behaviour ExternalService.RateLimiter

        @impl true
        def init(service, options) do
          {:ok, %{key: service, limit: options[:limit], window: options[:per]}}
        end

        @impl true
        def check(_service, config) do
          case MyStore.increment(config.key, config.window, config.limit) do
            {:ok, _count} -> :ok
            {:throttled, milliseconds} -> {:wait, milliseconds}
          end
        end
      end

  Then point a service at it:

      use ExternalService,
        rate_limit: [limit: 100, per: 1_000, backend: {MyApp.RateLimiter, some: :option}]

  Backends are **stateless modules**. `c:init/2` returns an opaque config term
  that is stored with the rest of the service state and handed back to every
  other callback, so a backend needs no process, supervisor, or registry of its
  own. Anything mutable it needs — an `:atomics` reference, a connection pool
  name, a remote key — travels in that term.

  Report a real time-to-next-window from `c:check/2` where you can. Callers sleep
  for exactly as long as you say, so an accurate answer paces calls precisely and
  makes the `:wait` budget meaningful.

  ## Driving a limiter directly

  Most of the time the limiter is driven for you: `ExternalService.call/3` checks
  it before running your function. The functions in this module are for the cases
  that fall outside a guarded call.

  `peek/1` asks whether a call would be admitted **without consuming anything**,
  which is what makes it safe to call speculatively:

      case ExternalService.RateLimiter.peek(:payments) do
        :ok -> start_expensive_work()
        {:wait, ms} -> {:error, {:busy, ms}}
      end

  `ExternalService.rate_limited?/1` is the boolean form, symmetric with
  `ExternalService.available?/1`.

  `request/1` is the write side: it consumes one call's worth of the budget
  without running anything, for traffic that reaches the service by some path
  other than `call/3`.

      # A batch endpoint that costs three calls against the quota.
      Enum.each(1..3, fn _ -> ExternalService.RateLimiter.request(:payments) end)

  Note that `request/1` blocks according to the service's `:wait` setting, just
  as a guarded call would.
  """

  alias ExternalService.RateLimited
  alias ExternalService.ServiceNotStarted

  require Errata
  require Logger

  @type service :: ExternalService.service()

  @typedoc "Backend-private state, produced by `c:init/2` and passed to every other callback."
  @type config :: term()

  @typedoc """
  A configured rate limiter.

  `nil` means the service is not rate limited, in which case calls pass straight
  through.
  """
  @type t :: %__MODULE__{} | nil

  @doc """
  Prepares the rate limiter for `service`.

  Receives the validated `:rate_limit` options (`:limit` and `:per`) with any
  backend-specific options merged in.
  """
  @callback init(service(), options :: keyword()) :: {:ok, config()}

  @doc """
  Reports whether a call may proceed now.

  Returns `:ok` when the call is within the limit, or `{:wait, milliseconds}`
  when it is not. Backends that can compute a real time-to-next-window should do
  so, so that callers sleep for the right amount of time rather than an estimate.
  """
  @callback check(service(), config()) :: :ok | {:wait, non_neg_integer()}

  @doc """
  Reports whether a call would be admitted right now, **without consuming**
  anything.

  Returns the same values as `c:check/2`, but must leave the limiter's state
  untouched so that callers can ask speculatively. Where a backend can only
  answer approximately, prefer erring toward `{:wait, _}` — a caller that skips
  work it could have done is cheaper than one that floods a service it should
  have waited for.
  """
  @callback peek(service(), config()) :: :ok | {:wait, non_neg_integer()}

  @default_backend ExternalService.RateLimiter.Local

  @typedoc """
  How long a throttled call may wait before giving up.

  `:infinity` waits as long as the limiter requires, `false` never waits, and an
  integer is a millisecond budget for the whole call.

  `nil` means the service never set `:wait`. It behaves exactly like `:infinity`,
  but `ExternalService.start/2` warns about it — see
  [Bounding the wait](rate-limiting.html#bounding-the-wait).
  """
  @type wait :: :infinity | false | non_neg_integer() | nil

  @typedoc """
  Returned by `call/2` when the wait budget was exhausted before the call could
  be admitted, carrying the milliseconds still remaining.
  """
  @type rate_limited :: {__MODULE__, :rate_limited, non_neg_integer()}

  defstruct [:service, :backend, :config, :sleep, :wait]

  @doc """
  Reports whether a call to `service` would be admitted right now, without
  consuming any of its budget.

  A service with no rate limit configured — including one that was never started
  — answers `:ok`, since nothing is holding calls back. Use
  `ExternalService.available?/1` if you need to know whether a service is ready
  to use.
  """
  @spec peek(service()) :: :ok | {:wait, non_neg_integer()}
  def peek(service) do
    case fetch(service) do
      {:ok, %__MODULE__{backend: module, config: config}} -> module.peek(service, config)
      # Not rate limited, or not started: nothing is making this call wait.
      _ -> :ok
    end
  end

  @doc """
  Consumes one call's worth of `service`'s rate limit without running anything.

  For traffic that reaches the service by some path other than
  `ExternalService.call/3` and should still count against the budget. Blocks
  according to the service's `:wait` setting, exactly as a guarded call would,
  and returns `ExternalService.RateLimited` if that budget runs out.
  """
  @spec request(service()) :: :ok | {:error, RateLimited.t() | ServiceNotStarted.t()}
  def request(service) do
    case fetch(service) do
      {:ok, rate_limiter} -> consume(service, rate_limiter)
      :not_started -> {:error, Errata.create(ServiceNotStarted, context: %{service: service})}
    end
  end

  defp consume(service, rate_limiter) do
    case call(rate_limiter, fn -> :ok end) do
      :ok ->
        :ok

      {__MODULE__, :rate_limited, retry_after} ->
        {:error,
         Errata.create(RateLimited, context: %{service: service, retry_after: retry_after})}
    end
  end

  defp fetch(service) do
    case ExternalService.State.fetch(service) do
      {:ok, %{rate_limit: rate_limiter}} -> {:ok, rate_limiter}
      :error -> :not_started
    end
  end

  # The functions below drive backends on `ExternalService`'s behalf, and take a
  # built limiter rather than resolving it from the service state. They are not
  # part of the public API.

  @doc false
  @spec default_backend() :: module()
  def default_backend, do: @default_backend

  @doc false
  @spec new(service(), keyword() | nil, keyword()) :: t()
  def new(service, options, opts \\ [])

  def new(_service, nil, _opts), do: nil

  def new(service, options, opts) when is_list(options) do
    # `:wait` governs the runtime rather than the backend, so it is taken out
    # before the remaining options are handed over. It has no schema default, so
    # an absent key arrives here as `nil` — "never set", which waits like
    # `:infinity` but warns.
    {wait, options} = Keyword.pop(options, :wait)
    {module, options} = split_backend(options)
    {:ok, config} = module.init(service, options)

    %__MODULE__{
      service: service,
      backend: module,
      config: config,
      wait: wait,
      sleep: Keyword.get(opts, :sleep_function, &Process.sleep/1)
    }
  end

  @doc false
  @spec call(t(), (-> any())) :: any() | rate_limited()
  def call(nil, function) when is_function(function, 0), do: function.()

  def call(%__MODULE__{} = rate_limiter, function) when is_function(function, 0),
    do: call(rate_limiter, function, deadline(rate_limiter.wait), 0)

  defp call(%__MODULE__{backend: module, config: config} = rate_limiter, fun, deadline, count) do
    case module.check(rate_limiter.service, config) do
      :ok ->
        fun.()

      {:wait, sleep_time} ->
        if past_deadline?(deadline, sleep_time) do
          {__MODULE__, :rate_limited, sleep_time}
        else
          emit_sleep(rate_limiter.service, sleep_time)
          log_sleep(rate_limiter.service, sleep_time, count)
          rate_limiter.sleep.(sleep_time)
          call(rate_limiter, fun, deadline, count + 1)
        end
    end
  end

  # The budget covers the whole call rather than any single sleep, so it is
  # resolved once into a monotonic deadline and then compared against.
  #
  # `nil` (never set) and `:infinity` (explicitly unbounded) behave identically;
  # they are distinguished only so that `start/2` can warn about the former.
  defp deadline(unbounded) when unbounded in [nil, :infinity], do: :infinity
  defp deadline(false), do: :none
  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  defp past_deadline?(:infinity, _sleep_time), do: false
  defp past_deadline?(:none, _sleep_time), do: true

  defp past_deadline?(deadline, sleep_time),
    do: System.monotonic_time(:millisecond) + sleep_time > deadline

  # `:backend` accepts either a bare module or a `{module, options}` tuple, with
  # the backend-specific options merged over the shared rate-limit options.
  defp split_backend(options) do
    case Keyword.pop(options, :backend, @default_backend) do
      {{module, backend_options}, options} -> {module, Keyword.merge(options, backend_options)}
      {module, options} -> {module, options}
    end
  end

  defp emit_sleep(service, sleep_time) do
    :telemetry.execute(
      [:external_service, :rate_limit, :sleep],
      %{sleep_time: sleep_time},
      %{service: service}
    )
  end

  # Only the first sleep of a throttled call is logged, so that a call that waits
  # through several windows does not flood the log.
  defp log_sleep(_service, _sleep_time, sleep_count) when sleep_count > 0, do: :ok

  defp log_sleep(service, sleep_time, _sleep_count) do
    Logger.info(fn ->
      [
        "[ExternalService] Rate limit exceeded for service ",
        inspect(service),
        "; sleeping for ",
        inspect(sleep_time),
        " milliseconds."
      ]
    end)
  end
end
