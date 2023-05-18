defmodule ExternalService do
  @moduledoc """
  ExternalService handles all retry and circuit breaker logic for calls to external services.
  """

  alias ExternalService.RetryOptions
  alias ExternalService.RateLimit
  alias :fuse, as: Fuse

  require Logger

  @typedoc "Name of a fuse"
  @type fuse_name :: term()

  @typedoc "Error tuple returned when the allowable number of retries has been exceeded"
  @type retries_exhausted :: {:error, {:retries_exhausted, reason :: any}}

  @typedoc "Error tuple returned when a fuse has been melted enough times that the fuse is blown"
  @type fuse_blown :: {:error, {:fuse_blown, fuse_name}}

  @typedoc "Error tuple returned when a fuse has not been initialized with `ExternalService.start/1`"
  @type fuse_not_found :: {:error, {:fuse_not_found, fuse_name}}

  @typedoc "Union type representing all the possible error tuple return values"
  @type error :: retries_exhausted | fuse_blown | fuse_not_found

  @type retriable_function_result ::
          :retry | {:retry, reason :: any()} | (function_result :: any())

  @type retriable_function :: (() -> retriable_function_result())

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

  defmodule RetriesExhaustedError do
    @moduledoc """
    Exception raised by `ExternalService.call!/3` when the allowable number of retries has been
    exceeded.
    """
    defexception [:message]
  end

  defmodule FuseBlownError do
    @moduledoc """
    Exception raised by `ExternalService.call!/3` when a fuse has been melted enough times that
    the fuse is blown.
    """
    defexception [:message]
  end

  defmodule FuseNotFoundError do
    @moduledoc """
    Exception raised by `ExternalService.call!/3` when a fuse has not been initialized with
    `ExternalService.start/1`.
    """
    defexception [:message]
  end

  defmodule State do
    @moduledoc false

    defstruct [:fuse_name, :fuse_options, :rate_limit]

    def init(fuse_name, fuse_options, rate_limit) do
      state = %__MODULE__{
        fuse_name: fuse_name,
        fuse_options: fuse_options,
        rate_limit: rate_limit
      }

      Agent.start(fn -> state end, name: registered_name(fuse_name))
      state
    end

    def get(fuse_name), do: Agent.get(registered_name(fuse_name), & &1)

    def registered_name(fuse_name), do: Module.concat(fuse_name, __MODULE__)
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
  """
  @spec stop(fuse_name()) :: :ok
  def stop(fuse_name) when is_atom(fuse_name) do
    :ok = Fuse.remove(fuse_name)
    :ok = State.registered_name(fuse_name) |> Agent.stop()
    :ok
  end

  @doc """
  Resets the given fuse.

  After reset, the fuse will be unbroken with no melts.
  """
  @spec reset_fuse(fuse_name()) :: :ok | {:error, :not_found}
  def reset_fuse(fuse_name), do: Fuse.reset(fuse_name)

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
    case call_with_retry(fuse_name, retry_opts, function) do
      {:no_retry, result} -> result
      {:error, :retry} -> {:error, {:retries_exhausted, :reason_unknown}}
      {:error, {:retry, reason}} -> {:error, {:retries_exhausted, reason}}
      result -> result
    end
  end

  @doc """
  Like `call/3`, but raises an exception if retries are exhausted or the fuse is blown.
  """
  @spec call!(fuse_name(), RetryOptions.t(), retriable_function()) ::
          function_result :: any | no_return
  def call!(fuse_name, retry_opts \\ %RetryOptions{}, function) do
    case call_with_retry(fuse_name, retry_opts, function) do
      {:no_retry, result} ->
        result

      {:error, :retry} ->
        raise ExternalService.RetriesExhaustedError, message: "fuse_name: #{fuse_name}"

      {:error, {:retry, reason}} ->
        raise ExternalService.RetriesExhaustedError,
          message: "reason: #{inspect(reason)}, fuse_name: #{fuse_name}"

      {:error, {:fuse_blown, fuse_name}} ->
        raise ExternalService.FuseBlownError, message: inspect(fuse_name)

      {:error, {:fuse_not_found, fuse_name}} ->
        raise ExternalService.FuseNotFoundError, message: fuse_not_found_message(fuse_name)
    end
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
          | fuse_blown
          | fuse_not_found
          | (function_result :: any())
  defp call_with_retry(fuse_name, retry_opts, function) do
    require Retry

    Retry.retry with: apply_retry_options(retry_opts), rescue_only: retry_opts.rescue_only do
      case Fuse.ask(fuse_name, :sync) do
        :ok -> try_function(fuse_name, function)
        :blown -> throw(:blown)
        {:error, :not_found} -> throw(:not_found)
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

    retry_opts
    |> Map.take([:randomize, :expiry, :cap])
    |> Enum.reduce(delay_stream, fn {key, value}, acc ->
      if value do
        apply(Retry.DelayStreams, key, [acc, value])
      else
        acc
      end
    end)
  end

  @spec try_function(fuse_name, retriable_function) ::
          {:error, {:retry, any}} | {:error, :retry} | {:no_retry, any} | no_return
  defp try_function(fuse_name, function) do
    rate_limit = State.get(fuse_name).rate_limit

    case RateLimit.call(rate_limit, function) do
      {:retry, reason} ->
        Fuse.melt(fuse_name)
        {:error, {:retry, reason}}

      :retry ->
        Fuse.melt(fuse_name)
        {:error, :retry}

      result ->
        {:no_retry, result}
    end
  rescue
    error ->
      Fuse.melt(fuse_name)
      reraise error, __STACKTRACE__
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
