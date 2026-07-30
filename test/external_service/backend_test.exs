defmodule ExternalService.BackendTest do
  @moduledoc """
  Covers the circuit breaker and rate limiter backend seam: that a service
  configured with a custom backend routes every operation through it, and that
  the shipped defaults are still what you get when you say nothing.
  """

  use ExUnit.Case

  alias ExternalService.CircuitBreaker
  alias ExternalService.RateLimiter
  alias ExternalService.Test.StubBreaker
  alias ExternalService.Test.StubLimiter

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
