defmodule ExternalService.RateLimit do
  @moduledoc false

  require Logger

  @opaque t :: %__MODULE__{
            fuse: ExternalService.fuse_name(),
            bucket: String.t(),
            limit: pos_integer,
            time_window: pos_integer,
            sleep: function
          }

  defstruct [:fuse, :bucket, :limit, :time_window, :sleep]

  defmacro is_rate_limit(limit, time_window) do
    quote do
      is_integer(unquote(limit)) and unquote(limit) > 0 and is_integer(unquote(time_window)) and
        unquote(time_window) > 0
    end
  end

  def new(fuse_name, fuse_opts, opts \\ [])

  def new(_fuse_name, nil, _opts), do: %__MODULE__{}

  def new(fuse_name, %{time_window: window, limit: limit}, opts),
    do: new(fuse_name, {limit, window}, opts)

  def new(fuse_name, fuse_opts, opts) when is_list(fuse_opts) do
    limit = Keyword.get(fuse_opts, :limit)
    time_window = Keyword.get(fuse_opts, :time_window)
    new(fuse_name, {limit, time_window}, opts)
  end

  def new(fuse_name, {limit, window}, opts) when is_rate_limit(limit, window) do
    bucket = bucket_name(fuse_name)

    rate_limit = %__MODULE__{
      fuse: fuse_name,
      bucket: bucket,
      limit: limit,
      time_window: window,
      sleep: Keyword.get(opts, :sleep_function, &Process.sleep/1)
    }

    rate_limit
  end

  def new(_fuse_name, _invalid_args, _options) do
    raise(ArgumentError, message: "Invalid rate limit arguments")
  end

  @spec call(t, (() -> any), non_neg_integer) :: any
  def call(rate_limit, function, sleep_count \\ 0)

  def call(
        %__MODULE__{bucket: bucket, limit: limit, time_window: window} = rate_limit,
        function,
        sleep_count
      )
      when is_rate_limit(limit, window) and is_function(function) do
    case ExRated.check_rate(bucket, window, limit) do
      {:ok, _} ->
        function.()

      {:error, _} ->
        sleep_time = sleep_time(rate_limit)
        log_sleep(rate_limit.fuse, bucket, limit, window, sleep_time, sleep_count)
        rate_limit.sleep.(sleep_time)
        call(rate_limit, function, sleep_count + 1)
    end
  end

  def call(%__MODULE__{}, function, _sleep_count) when is_function(function), do: function.()

  @spec bucket_name(atom) :: String.t()
  def bucket_name(root_fuse_name),
    do: to_string(Module.concat(root_fuse_name, __MODULE__))

  defp sleep_time(%__MODULE__{limit: limit, time_window: window}),
    do: trunc(Float.ceil(window / limit))

  defp log_sleep(fuse_name, bucket, limit, window, sleep_time, sleep_count) do
    if sleep_count == 0 do
      Logger.info(fn ->
        [
          "[ExternalService] Rate limit exceeded for service ",
          inspect(fuse_name),
          "; sleeping for ",
          inspect(sleep_time),
          " milliseconds."
        ]
      end)

      Logger.debug(fn ->
        [
          "[ExternalService] ExRated bucket info: ",
          inspect(ExRated.inspect_bucket(bucket, window, limit))
        ]
      end)
    end
  end
end
