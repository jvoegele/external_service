defmodule ExternalService.Gateway do
  @moduledoc """
  Deprecated. Use `use ExternalService` instead.

  `ExternalService.Gateway` was the original module-based gateway. In 2.0 the
  module-based front door moved to `ExternalService` itself, with a unified,
  validated configuration (`:circuit_breaker`/`:rate_limit`/`:retry`) and shorter
  generated function names (`call/1` instead of `external_call/1`).

  `use ExternalService.Gateway` still works but emits a deprecation warning. It
  delegates to `use ExternalService` and additionally generates the old
  `external_call/*` (and `reset_fuse/0`) function names as deprecated aliases.
  Note that the option shape is the same as `use ExternalService`: the old
  `fuse: [strategy:, refresh:]` options are no longer supported — see the
  migration guide.

  ## Migration

      # Before
      use ExternalService.Gateway,
        fuse: [name: MyService, strategy: {:standard, 5, 1_000}, refresh: 5_000],
        rate_limit: {100, 1_000},
        retry: [backoff: {:linear, 100, 1}, expiry: 5_000]

      def call_service(p), do: external_call(fn -> ... end)

      # After
      use ExternalService,
        name: MyService,
        circuit_breaker: [tolerate: 5, within: 1_000, reset: 5_000],
        rate_limit: [limit: 100, per: 1_000],
        retry: [backoff: :linear, base: 100, expiry: 5_000]

      def call_service(p), do: call(fn -> ... end)
  """

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      IO.warn(
        "use ExternalService.Gateway is deprecated; use `use ExternalService` instead",
        Macro.Env.stacktrace(__ENV__)
      )

      use ExternalService, opts

      @doc false
      def external_call(function) when is_function(function), do: call(function)
      def external_call(retry_opts, function), do: call(retry_opts, function)

      @doc false
      def external_call!(function) when is_function(function), do: call!(function)
      def external_call!(retry_opts, function), do: call!(retry_opts, function)

      @doc false
      def external_call_async(function) when is_function(function), do: call_async(function)
      def external_call_async(retry_opts, function), do: call_async(retry_opts, function)

      @doc false
      def external_call_async_stream(enumerable, function) when is_function(function),
        do: call_async_stream(enumerable, function)

      @doc false
      def external_call_async_stream(enumerable, retry_opts_or_async_opts, function),
        do: call_async_stream(enumerable, retry_opts_or_async_opts, function)

      @doc false
      def external_call_async_stream(enumerable, retry_opts, async_opts, function),
        do: call_async_stream(enumerable, retry_opts, async_opts, function)

      @doc false
      def reset_fuse, do: reset()
    end
  end
end
