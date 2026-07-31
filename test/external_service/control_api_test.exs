defmodule ExternalService.ControlApiTest do
  @moduledoc """
  Covers the public control API: driving a service's circuit breaker and rate
  limiter directly, outside a guarded call.
  """

  use ExUnit.Case

  alias ExternalService.CircuitBreaker
  alias ExternalService.RateLimited
  alias ExternalService.RateLimiter
  alias ExternalService.ServiceNotStarted

  @moduletag capture_log: true

  defp unique_service, do: :"control_test_#{System.unique_integer([:positive])}"

  defp start_service(options) do
    service = unique_service()
    :ok = ExternalService.start(service, options)
    on_exit(fn -> ExternalService.stop(service) end)
    service
  end

  describe "CircuitBreaker.melt/1" do
    test "records a failure that happened outside a guarded call" do
      service = start_service(circuit_breaker: [tolerate: 2, within: 10_000])

      assert ExternalService.available?(service)

      assert CircuitBreaker.melt(service) == :ok
      assert CircuitBreaker.melt(service) == :ok
      assert ExternalService.available?(service), "should survive its tolerance"

      assert CircuitBreaker.melt(service) == :ok
      assert ExternalService.blown?(service)
    end

    test "a breaker opened by melting rejects guarded calls" do
      service = start_service(circuit_breaker: [tolerate: 1, within: 10_000])

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)

      assert {:error, %ExternalService.CircuitBreakerOpen{context: %{service: ^service}}} =
               ExternalService.call(service, fn -> :never_runs end)
    end

    test "reset/1 undoes it" do
      service = start_service(circuit_breaker: [tolerate: 1, within: 10_000])

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)
      assert ExternalService.blown?(service)

      assert CircuitBreaker.reset(service) == :ok
      assert ExternalService.available?(service)
    end

    test "reports an unstarted service rather than raising" do
      assert CircuitBreaker.melt(:never_started_service) == {:error, :not_found}
      assert CircuitBreaker.reset(:never_started_service) == {:error, :not_found}
    end
  end

  describe "CircuitBreaker.ask/1" do
    test "distinguishes open, closed, and never started" do
      service = start_service(circuit_breaker: [tolerate: 1, within: 10_000])

      assert CircuitBreaker.ask(service) == :ok

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)
      assert CircuitBreaker.ask(service) == :blown

      assert CircuitBreaker.ask(:never_started_service) == :not_started
    end

    test "the facade booleans agree with it" do
      service = start_service(circuit_breaker: [tolerate: 1, within: 10_000])

      assert ExternalService.available?(service)
      refute ExternalService.blown?(service)

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)

      refute ExternalService.available?(service)
      assert ExternalService.blown?(service)

      # A service that was never started is neither.
      refute ExternalService.available?(:never_started_service)
      refute ExternalService.blown?(:never_started_service)
    end
  end

  describe "RateLimiter.peek/1" do
    test "does not consume any of the budget" do
      service = start_service(rate_limit: [limit: 3, per: :timer.minutes(1)])

      # Peeking a hundred times must not use up a limit of three.
      Enum.each(1..100, fn _ -> assert RateLimiter.peek(service) == :ok end)

      assert Enum.map(1..3, fn _ -> ExternalService.call(service, fn -> :ok end) end) ==
               [:ok, :ok, :ok]
    end

    test "reports the wait once the budget is spent" do
      service = start_service(rate_limit: [limit: 2, per: 1_000, wait: false])

      Enum.each(1..2, fn _ -> ExternalService.call(service, fn -> :ok end) end)

      assert {:wait, ms} = RateLimiter.peek(service)
      assert is_integer(ms) and ms > 0
    end

    test "agrees with what a call would actually do" do
      service = start_service(rate_limit: [limit: 1, per: :timer.minutes(1), wait: false])

      assert RateLimiter.peek(service) == :ok
      assert ExternalService.call(service, fn -> :ok end) == :ok

      assert {:wait, _} = RateLimiter.peek(service)

      assert {:error, %RateLimited{}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)
    end

    test "a service with no rate limit is never waiting" do
      service = start_service(circuit_breaker: [tolerate: 1])
      assert RateLimiter.peek(service) == :ok
    end

    test "an unstarted service is never waiting" do
      assert RateLimiter.peek(:never_started_service) == :ok
    end
  end

  describe "ExternalService.rate_limited?/1" do
    test "is the boolean form of peek/1" do
      service = start_service(rate_limit: [limit: 1, per: :timer.minutes(1), wait: false])

      refute ExternalService.rate_limited?(service)

      assert ExternalService.call(service, fn -> :ok end) == :ok

      assert ExternalService.rate_limited?(service)
    end

    test "is false for services without a rate limit, and for unstarted ones" do
      service = start_service(circuit_breaker: [tolerate: 1])

      refute ExternalService.rate_limited?(service)
      refute ExternalService.rate_limited?(:never_started_service)
    end

    test "asking does not itself consume budget" do
      service = start_service(rate_limit: [limit: 2, per: :timer.minutes(1), wait: false])

      Enum.each(1..50, fn _ -> refute ExternalService.rate_limited?(service) end)

      # Both calls still available despite fifty checks.
      assert ExternalService.call(service, fn -> :one end) == :one
      assert ExternalService.call(service, fn -> :two end) == :two
      assert ExternalService.rate_limited?(service)
    end
  end

  describe "RateLimiter.request/1" do
    test "consumes budget without running anything" do
      service = start_service(rate_limit: [limit: 2, per: :timer.minutes(1), wait: false])

      assert RateLimiter.request(service) == :ok
      assert RateLimiter.request(service) == :ok

      assert ExternalService.rate_limited?(service)

      assert {:error, %RateLimited{context: %{service: ^service}}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)
    end

    test "returns RateLimited when the wait budget runs out" do
      service = start_service(rate_limit: [limit: 1, per: :timer.minutes(1), wait: false])

      assert RateLimiter.request(service) == :ok

      assert {:error, %RateLimited{context: context}} = RateLimiter.request(service)
      assert context.service == service
      assert is_integer(context.retry_after)
    end

    test "a service with no rate limit always admits" do
      service = start_service(circuit_breaker: [tolerate: 1])
      assert RateLimiter.request(service) == :ok
    end

    test "reports an unstarted service" do
      assert {:error, %ServiceNotStarted{context: %{service: :never_started_service}}} =
               RateLimiter.request(:never_started_service)
    end

    test "does not touch the circuit breaker" do
      service = start_service(rate_limit: [limit: 1, per: :timer.minutes(1), wait: false])

      assert RateLimiter.request(service) == :ok
      assert {:error, %RateLimited{}} = RateLimiter.request(service)

      assert ExternalService.available?(service)
    end
  end
end
