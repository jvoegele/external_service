defmodule ExternalService.Gateway do
  @moduledoc """
  Defines a gateway to an external service.

  `ExternalService.Gateway` allows for defining module-based gateways to external services.
  Instead of explicitly starting a fuse with its configuration and separately passing in retry
  options on each call to the service, a module-based gateway allows one to specify default fuse
  and retry options at the module level.

  When a module uses the `ExternalService.Gateway` module, an implementation of the
  `ExternalService.Gateway` behaviour will be generated using the fuse, retry, and rate-limit
  options provided to the `use ExternalService.Gateway` statement. See the documentation for the
  various callbacks in this module for more details.

  ## Example

      defmodule MyApp.SomeService do
        use ExternalService.Gateway,
          fuse: [
            # Tolerate 5 failures for every 1 second time window.
            strategy: {:standard, 5, 10_000},
            # Reset the fuse 5 seconds after it is blown.
            refresh: 5_000
          ],
          # Limit to 5 calls per second.
          rate_limit: {5, :timer.seconds(1)},
          retry: [
            # Use linear backoff. Exponential backoff is also available.
            backoff: {:linear, 100, 1},
            # Stop retrying after 5 seconds.
            expiry: 5_000
          ]

        def call_the_service(params) do
          external_call fn ->
            # Call the service with params, then return the result or :retry.
            case do_call(params) do
              {:ok, result} -> {:ok, result}
              {:error, reason} -> {:retry, reason}
            end
          end
        end
      end
  """

  alias ExternalService.RetryOptions

  @doc """
  Invoked to call the given function using the retry options configured for the gateway.

  See `ExternalService.call/3` for more information.
  """
  @callback external_call(ExternalService.retriable_function()) ::
              ExternalService.error() | (function_result :: any)

  @doc """
  Invoked to call the given function using custom retry options.

  See `ExternalService.call/3` for more information.
  """
  @callback external_call(RetryOptions.t(), ExternalService.retriable_function()) ::
              ExternalService.error() | (function_result :: any)

  @doc """
  Like `external_call/1`, but raises an exception if retries are exhausted or the fuse is blown.

  See `ExternalService.call!/3` for more information.
  """
  @callback external_call!(ExternalService.retriable_function()) ::
              function_result :: any | no_return

  @doc """
  Like `external_call/2`, but raises an exception if retries are exhausted or the fuse is blown.

  See `ExternalService.call!/3` for more information.
  """
  @callback external_call!(RetryOptions.t(), ExternalService.retriable_function()) ::
              function_result :: any | no_return

  @doc """
  Asynchronous version of `external_call/1`.

  Returns a `Task` that may be used to retrieve the result of the async call.

  See `ExternalService.call_async` for more information.
  """
  @callback external_call_async(ExternalService.retriable_function()) :: Task.t()

  @doc """
  Asynchronous version of `external_call/2`.

  Returns a `Task` that may be used to retrieve the result of the async call.

  See `ExternalService.call_async` for more information.
  """
  @callback external_call_async(RetryOptions.t(), ExternalService.retriable_function()) ::
              Task.t()

  @doc """
  Parallel, streaming version of `external_call/1`.

  See `ExternalService.call_async_stream/5` for more information.
  """
  @callback external_call_async_stream(
              Enumerable.t(),
              (any() -> ExternalService.retriable_function_result())
            ) ::
              Enumerable.t()

  @doc """
  Parallel, streaming version of `external_call/2`.

  See `ExternalService.call_async_stream/5` for more information.
  """
  @callback external_call_async_stream(
              Enumerable.t(),
              RetryOptions.t() | (async_opts :: list()),
              (any() -> ExternalService.retriable_function_result())
            ) ::
              Enumerable.t()

  @doc """
  Parallel, streaming version of `external_call/2`.

  See `ExternalService.call_async_stream/5` for more information.
  """
  @callback external_call_async_stream(
              Enumerable.t(),
              RetryOptions.t(),
              async_opts :: list(),
              (any() -> ExternalService.retriable_function_result())
            ) ::
              Enumerable.t()

  defmacro __using__(opts) do
    quote do
      @behaviour ExternalService.Gateway

      alias ExternalService.RetryOptions

      @opts unquote(opts)

      @doc """
      Returns a child specification to start a gateway under a supervisor.
      """
      def child_spec(opts) do
        %{id: __MODULE__, type: :worker, start: {__MODULE__, :start_link, [opts]}}
      end

      @doc """
      Starts a gateway linked to the current process.
      """
      def start_link(opts) do
        ExternalService.Gateway.start_link(__MODULE__, @opts, opts)
      end

      @doc """
      Returns the configuration with which the gateway was started.
      """
      def gateway_config, do: ExternalService.Gateway.get_config(__MODULE__)

      @impl ExternalService.Gateway
      def external_call(retry_opts \\ nil, function) do
        config = get_config()
        ExternalService.call(fuse_name(config), retry_opts(retry_opts, config), function)
      end

      @impl ExternalService.Gateway
      def external_call!(retry_opts \\ nil, function) do
        config = get_config()
        ExternalService.call!(fuse_name(config), retry_opts(retry_opts, config), function)
      end

      @impl ExternalService.Gateway
      def external_call_async(retry_opts \\ nil, function) do
        config = get_config()
        ExternalService.call_async(fuse_name(config), retry_opts(retry_opts, config), function)
      end

      @impl ExternalService.Gateway
      def external_call_async_stream(enumerable, function) do
        config = get_config()
        ExternalService.call_async_stream(enumerable, fuse_name(config), function)
      end

      @impl ExternalService.Gateway
      def external_call_async_stream(enumerable, retry_opts_or_async_opts, function) do
        config = get_config()

        ExternalService.call_async_stream(
          enumerable,
          fuse_name(config),
          retry_opts_or_async_opts,
          function
        )
      end

      @impl ExternalService.Gateway
      def external_call_async_stream(enumerable, retry_opts, async_opts, function) do
        config = get_config()

        ExternalService.call_async_stream(
          enumerable,
          fuse_name(config),
          retry_opts,
          async_opts,
          function
        )
      end

      defp retry_opts(nil, config), do: RetryOptions.new(config[:retry])
      defp retry_opts(%RetryOptions{} = retry_opts, _config), do: retry_opts
      defp retry_opts(opts, _config), do: RetryOptions.new(opts)

      defp fuse_name(config), do: get_in(config, [:fuse, :name])

      defp get_config, do: ExternalService.Gateway.get_config(__MODULE__)

      defp get_config(key, default \\ nil), do: Keyword.get(get_config(), key, default)
    end
  end

  @doc false
  def start_link(module, module_opts, start_opts)
      when is_list(module_opts) and is_list(start_opts) do
    config = DeepMerge.deep_merge(module_opts, start_opts)
    {fuse_name, fuse_opts} = config |> Keyword.get(:fuse, []) |> Keyword.pop(:name, module)
    service_start_opts = Keyword.merge(fuse_opts, Keyword.take(config, [:rate_limit]))
    :ok = ExternalService.start(fuse_name, service_start_opts)

    Agent.start_link(
      fn -> Keyword.put(config, :fuse, Keyword.put(fuse_opts, :name, fuse_name)) end,
      name: config_agent(module)
    )
  end

  @doc false
  def get_config(module), do: Agent.get(config_agent(module), & &1)

  defp config_agent(module), do: Module.concat(module, Config)
end
