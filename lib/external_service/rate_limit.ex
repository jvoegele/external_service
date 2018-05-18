defmodule ExternalService.RateLimit do
  @moduledoc false

  require Logger

  @opaque t :: %__MODULE__{
            bucket: String.t(),
            limit: pos_integer,
            time_window: pos_integer,
            sleep: function
          }

  defstruct [:bucket, :limit, :time_window, :sleep]

  defmacro is_rate_limit(limit, time_window) do
    quote do
      is_integer(unquote(limit)) and unquote(limit) > 0 and is_integer(unquote(time_window)) and
        unquote(time_window) > 0
    end
  end

  def new(_fuse_name, nil), do: %__MODULE__{}

  def new(fuse_name, %{time_window: window, limit: limit}), do: new(fuse_name, {limit, window})

  def new(fuse_name, opts) when is_list(opts),
    do: new(fuse_name, {Keyword.get(opts, :limit), Keyword.get(opts, :time_window)})

  def new(fuse_name, {limit, window}) when is_rate_limit(limit, window) do
    bucket = bucket_name(fuse_name)

    rate_limit = %__MODULE__{
      bucket: bucket,
      limit: limit,
      time_window: window,
      sleep: make_sleep_fun(fuse_name, bucket, limit, window)
    }

    rate_limit
  end

  def new(_fuse_name, _invalid_args) do
    raise(ArgumentError, message: "Invalid rate limit arguments")
  end

  @spec call(t, (() -> any)) :: any
  def call(%__MODULE__{limit: limit, time_window: window} = rate_limit, function)
      when is_rate_limit(limit, window) and is_function(function) do
    case ExRated.check_rate(rate_limit.bucket, window, limit) do
      {:ok, _} ->
        function.()

      {:error, _} ->
        rate_limit.sleep.(sleep_time(rate_limit))
        call(rate_limit, function)
    end
  end

  def call(%__MODULE__{}, function) when is_function(function), do: function.()

  @spec bucket_name(atom) :: String.t()
  def bucket_name(root_fuse_name) when is_atom(root_fuse_name),
    do: to_string(Module.concat(root_fuse_name, __MODULE__))

  defp sleep_time(%__MODULE__{limit: limit, time_window: window}),
    do: trunc(Float.ceil(window / limit))

  defp make_sleep_fun(fuse_name, bucket, limit, window) do
    fn sleep_time ->
      Logger.info(fn ->
        [
          "[ExternalService] ",
          "Rate limit exceeded for service ",
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

      Process.sleep(sleep_time)
    end

  end
end
