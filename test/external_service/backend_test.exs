defmodule ExternalService.BackendTest do
  @moduledoc """
  Covers the circuit breaker and rate limiter backend seam: that a service
  configured with a custom backend routes every operation through it, and that
  the shipped defaults are still what you get when you say nothing.
  """

  use ExUnit.Case

  alias ExternalService.CircuitBreaker
  alias ExternalService.RateLimiter
  alias ExternalService.TestSupport.StubBreaker
  alias ExternalService.TestSupport.StubLimiter

  @moduletag capture_log: true

  setup do
    StubBreaker.reset_stub()
    StubLimiter.reset()
    :ok
  end

  describe "defaults" do
    test "a service with no :backend uses the shipped implementations" do
      service = unique_service()
      :ok = ExternalService.start(service, rate_limit: [limit: 10, per: 1_000])
      on_exit(fn -> ExternalService.stop(service) end)

      state = ExternalService.State.get(service)

      assert {breaker_backend, _config} = state.circuit_breaker
      assert breaker_backend == CircuitBreaker.default_backend()
      assert %RateLimiter{backend: backend} = state.rate_limit
      assert backend == RateLimiter.default_backend()
    end
  end

  describe "circuit breaker backend" do
    test "every breaker operation is dispatched to the configured backend" do
      service = unique_service()
      :ok = ExternalService.start(service, circuit_breaker: [backend: StubBreaker])
      on_exit(fn -> ExternalService.stop(service) end)

      assert StubBreaker.call_names() == [:install]

      assert ExternalService.available?(service)
      refute ExternalService.blown?(service)
      assert ExternalService.call(service, fn -> :ok end) == :ok
      assert ExternalService.reset(service) == :ok
      :ok = ExternalService.stop(service)

      assert StubBreaker.call_names() == [:install, :ask, :ask, :ask, :reset, :remove]
      assert Enum.all?(StubBreaker.calls(), fn {_op, name} -> name == service end)
    end

    test "a retried result melts through the configured backend" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          circuit_breaker: [backend: StubBreaker],
          retry: [max_attempts: 3, base: 1]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert {:error, %ExternalService.RetriesExhausted{}} =
               ExternalService.call(service, fn -> {:retry, :nope} end)

      # One melt for the call, under the default `melt: :per_call` — the three
      # attempts are the retry mechanism's business, not the breaker's.
      assert Enum.count(StubBreaker.call_names(), &(&1 == :melt)) == 1
    end

    test "melt: :per_attempt charges the configured backend once per attempt" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          circuit_breaker: [backend: StubBreaker, melt: :per_attempt],
          retry: [max_attempts: 3, base: 1]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert {:error, %ExternalService.RetriesExhausted{}} =
               ExternalService.call(service, fn -> {:retry, :nope} end)

      assert Enum.count(StubBreaker.call_names(), &(&1 == :melt)) == 3
    end

    test "a backend reporting :blown produces CircuitBreakerOpen" do
      service = unique_service()
      :ok = ExternalService.start(service, circuit_breaker: [backend: StubBreaker])
      on_exit(fn -> ExternalService.stop(service) end)

      StubBreaker.blow()

      assert ExternalService.blown?(service)
      refute ExternalService.available?(service)

      assert {:error, %ExternalService.CircuitBreakerOpen{context: %{service: ^service}}} =
               ExternalService.call(service, fn -> :never_runs end)
    end

    test "backend options are passed through and merged with the shared options" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          circuit_breaker: [tolerate: 3, backend: {StubBreaker, [region: :eu]}]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert {StubBreaker, config} = ExternalService.State.get(service).circuit_breaker
      assert config.tolerate == 3
      assert config.region == :eu
    end
  end

  describe "rate limiter backend" do
    test "calls are checked against the configured backend" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          rate_limit: [limit: 1, per: 1_000, backend: {StubLimiter, [wait: 1]}],
          sleep_function: fn _ -> :ok end
        )

      on_exit(fn -> ExternalService.stop(service) end)

      StubLimiter.deny_next(1)
      assert ExternalService.call(service, fn -> :through end) == :through
    end
  end

  describe "rate limit wait budget" do
    test "a throttled call returns RateLimited without melting the circuit breaker" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          rate_limit: [limit: 1, per: :timer.minutes(1), wait: false]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert ExternalService.call(service, fn -> :first end) == :first

      assert {:error, %ExternalService.RateLimited{context: context}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)

      assert context.service == service
      assert is_integer(context.retry_after)

      # Being throttled is this library's own back-pressure, not a failure of the
      # external service, so it must leave the breaker alone.
      assert ExternalService.available?(service)
    end

    test "call!/3 raises RateLimited" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          rate_limit: [limit: 1, per: :timer.minutes(1), wait: false]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert ExternalService.call!(service, fn -> :first end) == :first

      assert_raise ExternalService.RateLimited, fn ->
        ExternalService.call!(service, fn -> flunk("should not have run") end)
      end
    end

    test "a throttled call is not retried" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          rate_limit: [limit: 1, per: :timer.minutes(1), wait: false],
          retry: [max_attempts: 5, base: 1]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert ExternalService.call(service, fn -> :first end) == :first

      Process.put(:attempts, 0)

      assert {:error, %ExternalService.RateLimited{}} =
               ExternalService.call(service, fn ->
                 Process.put(:attempts, Process.get(:attempts) + 1)
                 :ok
               end)

      # Retrying a throttled call would only be throttled again.
      assert Process.get(:attempts) == 0
    end
  end

  describe "option validation" do
    test "rejects a backend that is neither a module nor a {module, options} tuple" do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExternalService.start(unique_service(), circuit_breaker: [backend: "nope"])
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        ExternalService.start(unique_service(), rate_limit: [limit: 1, per: 1, backend: 42])
      end
    end
  end

  defp unique_service, do: :"backend_test_#{System.unique_integer([:positive])}"
end
