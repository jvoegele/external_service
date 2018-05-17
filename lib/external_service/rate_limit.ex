defmodule ExternalService.RateLimit do
  @moduledoc false

  alias :fuse, as: Fuse

  @opaque t :: %__MODULE__{
            fuse: atom,
            limit: pos_integer,
            time_window: pos_integer,
            sleep: function
          }

  defstruct [:fuse, :limit, :time_window, :sleep]

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
    fuse = fuse_name(fuse_name)

    rate_limit = %__MODULE__{
      fuse: fuse,
      limit: limit,
      time_window: window,
      sleep: &Process.sleep/1
    }

    :ok = install_fuse(rate_limit)

    rate_limit
  end

  def new(_fuse_name, _invalid_args) do
    raise(ArgumentError, message: "Invalid rate limit arguments")
  end

  def call(%__MODULE__{limit: limit, time_window: window} = rate_limit, function)
      when is_rate_limit(limit, window) and is_function(function) do
    case Fuse.ask(rate_limit.fuse, :sync) do
      :ok ->
        Fuse.melt(rate_limit.fuse)
        function.()

      :blown ->
        rate_limit.sleep.(window)
        call(rate_limit, function)
    end
  end

  def call(%__MODULE__{}, function) when is_function(function), do: function.()

  def fuse_name(root_fuse_name) when is_atom(root_fuse_name),
    do: Module.concat(root_fuse_name, __MODULE__)

  defp install_fuse(%{fuse: fuse, limit: limit, time_window: window}) do
    fuse_opts = {
      {:standard, limit - 1, window},
      {:reset, window}
    }

    :ok = Fuse.install(fuse, fuse_opts)
  end
end
