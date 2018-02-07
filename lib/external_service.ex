defmodule ExternalService do
  @moduledoc """
  ExternalService handles all retry and circuit breaker logic for calls to external services.
  """

  use Retry
  alias :fuse, as: Fuse

  defmodule RetryOptions do
    @moduledoc """
    Options used for controlling retry logic.
    See the [retry docs](https://hexdocs.pm/retry/Retry.html) for information about the available
    retry options.
    """

    defstruct backoff: {:exponential, 10},
              randomize: false,
              expiry: nil,
              cap: nil

    @type t :: %__MODULE__{
            backoff: {:exponential, pos_integer()} | {:linear, pos_integer(), pos_integer()},
            randomize: boolean(),
            expiry: pos_integer() | nil,
            cap: pos_integer() | nil
          }
  end

  defmodule RetriesExhausted do
    defexception [:message]
  end

  defmodule FuseBlown do
    defexception [:message]
  end

  defmodule FuseNotFound do
    defexception [:message]
  end

  @type fuse_name :: atom()
  @type retriable_function_result :: :retry | {:retry, reason :: any()} | function_result :: any()
  @type retriable_function :: (() -> retriable_function_result())
  @type retries_exhausted :: {:error, {:retries_exhausted, reason :: any}}
  @type fuse_blown :: {:error, {:fuse_blown, fuse_name}}
  @type fuse_not_found :: {:error, {:fuse_not_found, fuse_name}}
  @type error :: retries_exhausted | fuse_blown | fuse_not_found

  @typedoc """
  Options used for controlling circuit breaker behavior.
  See the [fuse docs](https://hexdocs.pm/fuse/) for information about available fuse options.
  """
  @type fuse_options :: [
          fuse_strategy: {:standard, pos_integer(), pos_integer()},
          fuse_refresh: pos_integer()
        ]

  @default_fuse_options %{
    fuse_strategy: {:standard, 10, 10_000},
    fuse_refresh: 60_000
  }

  @doc """
  Initializes a new fuse for a given service.
  """
  @spec start(fuse_name(), fuse_options()) :: :ok
  def start(fuse_name, fuse_options \\ []) do
    fuse_opts = {
      Keyword.get(fuse_options, :fuse_strategy, @default_fuse_options.fuse_strategy),
      {:reset, Keyword.get(fuse_options, :fuse_refresh, @default_fuse_options.fuse_refresh)}
    }

    :ok = Fuse.install(fuse_name, fuse_opts)
  end

  @doc """
  Given a fuse name and retry options execute a function handling any retry and circuit breaker
  logic. `ExternalService.start` must be run with the fuse name before using call.

  The provided function can indicate that a retry should be performed by returning the atom
  `:retry` or a tuple of the form `{:retry, reason}`, where `reason` is any arbitrary term, or by
  raising a `RuntimeError`. Any other result is considered successful so the operation will not be
  retried and the result of the function will be returned as the result of `call`.
  """
  @spec call(fuse_name(), RetryOptions.t(), retriable_function()) ::
          error | function_result :: any
  def call(fuse_name, retry_opts \\ %RetryOptions{}, function) do
    case do_retry(fuse_name, retry_opts, function) do
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
    case do_retry(fuse_name, retry_opts, function) do
      {:no_retry, result} ->
        result

      {:error, :retry} ->
        raise ExternalService.RetriesExhausted, message: "fuse_name: #{fuse_name}"

      {:error, {:retry, reason}} ->
        raise ExternalService.RetriesExhausted,
          message: "reason: #{inspect(reason)}, fuse_name: #{fuse_name}"

      {:error, {:fuse_blown, fuse_name}} ->
        raise ExternalService.FuseBlown, message: Atom.to_string(fuse_name)

      {:error, {:fuse_not_found, fuse_name}} ->
        raise ExternalService.FuseNotFound, message: Atom.to_string(fuse_name)
    end
  end

  @doc """
  An async version of `ExternalService.call`. Returns a `Task` that may be used to retrieve the
  result of the async call.
  """
  @spec call_async(fuse_name(), RetryOptions.t(), retriable_function()) :: Task.t()
  def call_async(fuse_name, retry_opts \\ %RetryOptions{}, function) do
    Task.async(fn -> call(fuse_name, retry_opts, function) end)
  end

  @doc """
  A parallel, streaming version of `ExternalService.call`.

  See `call_async_stream/5` for full documentation.
  """
  @spec call_async_stream(Enumerable.t(), fuse_name(), (any() -> retriable_function_result())) ::
          Enumerable.t()
  def call_async_stream(enumerable, fuse_name, function) when is_function(function),
    do: call_async_stream(enumerable, fuse_name, %RetryOptions{}, [], function)

  @doc """
  A parallel, streaming version of `ExternalService.call`.

  See `call_async_stream/5` for full documentation.
  """
  @spec call_async_stream(
          Enumerable.t(),
          fuse_name(),
          RetryOptions.t() | async_opts :: list(),
          (any() -> retriable_function_result())
        ) :: Enumerable.t()
  def call_async_stream(enumerable, fuse_name, retry_opts = %RetryOptions{}, function)
      when is_function(function),
      do: call_async_stream(enumerable, fuse_name, retry_opts, [], function)

  def call_async_stream(enumerable, fuse_name, async_opts, function)
      when is_list(async_opts) and is_function(function),
      do: call_async_stream(enumerable, fuse_name, %RetryOptions{}, async_opts, function)

  @doc """
  A parallel, streaming version of `ExternalService.call`. This function uses Elixir's built-in
  `Task.async_stream/3` function and the description below is taken from there.

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

  @spec do_retry(fuse_name(), RetryOptions.t(), retriable_function()) ::
          {:no_retry, function_result :: any()}
          | {:error, :retry}
          | {:error, {:retry, reason :: any()}}
          | fuse_blown
          | fuse_not_found
          | function_result :: any()
  defp do_retry(fuse_name, retry_opts, function) do
    retry with: apply_retry_options(retry_opts) do
      case Fuse.ask(fuse_name, :sync) do
        :ok -> try_function(fuse_name, function)
        :blown -> throw(:blown)
        {:error, :not_found} -> throw(:not_found)
      end
    end
  catch
    :blown -> {:error, {:fuse_blown, fuse_name}}
    :not_found -> {:error, {:fuse_not_found, fuse_name}}
  end

  defp apply_retry_options(retry_opts) do
    delay_stream =
      case retry_opts.backoff do
        {:exponential, initial_delay} -> exp_backoff(initial_delay)
        {:linear, initial_delay, factor} -> lin_backoff(initial_delay, factor)
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

  @spec try_function(atom, retriable_function) ::
          {:error, {:retry, any}} | {:error, :retry} | {:no_retry, any} | no_return
  defp try_function(fuse_name, function) do
    case function.() do
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
      reraise error, System.stacktrace()
  end
end
