defmodule ExternalService.RateLimiter do
  @moduledoc false

  # The rate limiter seam, and the runtime that drives it.
  #
  # A backend answers exactly one question — may a call proceed right now, and if
  # not, how long until it may? Everything else (sleeping, telemetry, logging) is
  # handled here, so that backends stay small and consistent.
  #
  # Like circuit breaker backends, rate limiter backends are *stateless modules*:
  # `init/2` returns an opaque config term that is stored with the rest of the
  # service state and handed back to `check/2`.

  require Logger

  @type service :: ExternalService.service()

  @typedoc "Backend-private state, produced by `c:init/2` and passed to `c:check/2`."
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

  @default_backend ExternalService.RateLimiter.ExRated

  defstruct [:service, :backend, :config, :sleep]

  @doc "The backend used when no `:backend` option is given."
  @spec default_backend() :: module()
  def default_backend, do: @default_backend

  @doc """
  Builds the rate limiter for a service, or `nil` when no `:rate_limit` options
  were given.
  """
  @spec new(service(), keyword() | nil, keyword()) :: t()
  def new(service, options, opts \\ [])

  def new(_service, nil, _opts), do: nil

  def new(service, options, opts) when is_list(options) do
    {module, options} = split_backend(options)
    {:ok, config} = module.init(service, options)

    %__MODULE__{
      service: service,
      backend: module,
      config: config,
      sleep: Keyword.get(opts, :sleep_function, &Process.sleep/1)
    }
  end

  @doc """
  Invokes `function`, first waiting as long as the rate limit requires.
  """
  @spec call(t(), (-> any())) :: any()
  def call(nil, function) when is_function(function, 0), do: function.()

  def call(%__MODULE__{} = rate_limiter, function) when is_function(function, 0),
    do: call(rate_limiter, function, 0)

  defp call(%__MODULE__{backend: module, config: config} = rate_limiter, function, sleep_count) do
    case module.check(rate_limiter.service, config) do
      :ok ->
        function.()

      {:wait, sleep_time} ->
        emit_sleep(rate_limiter.service, sleep_time)
        log_sleep(rate_limiter.service, sleep_time, sleep_count)
        rate_limiter.sleep.(sleep_time)
        call(rate_limiter, function, sleep_count + 1)
    end
  end

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
