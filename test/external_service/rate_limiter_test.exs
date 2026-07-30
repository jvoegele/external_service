defmodule ExternalService.RateLimiterTest do
  use ExUnit.Case

  alias ExternalService.RateLimiter
  alias ExternalService.Test.StubLimiter

  @moduletag capture_log: true

  describe "new/3" do
    test "returns nil when there are no rate limit options" do
      assert RateLimiter.new(:foo, nil) == nil
    end

    test "uses the default backend when none is given" do
      assert %RateLimiter{service: :foo, backend: backend} =
               RateLimiter.new(:foo, limit: 10, per: 100)

      assert backend == RateLimiter.default_backend()
    end

    test "accepts a backend module" do
      assert %RateLimiter{backend: StubLimiter, config: config} =
               RateLimiter.new(:foo, limit: 10, per: 100, backend: StubLimiter)

      assert config == %{limit: 10, per: 100}
    end

    test "accepts a {backend, options} tuple, merging the backend options in" do
      assert %RateLimiter{backend: StubLimiter, config: config} =
               RateLimiter.new(:foo,
                 limit: 10,
                 per: 100,
                 backend: {StubLimiter, [flavor: :vanilla]}
               )

      assert config == %{limit: 10, per: 100, flavor: :vanilla}
    end
  end

  describe "call/2" do
    setup [:init_sleep_spy]

    test "runs the function directly when there is no rate limit" do
      rate_limiter = RateLimiter.new(:unlimited, nil)
      assert RateLimiter.call(rate_limiter, fn -> 42 end) == 42
      assert get_sleep_calls() == []
    end

    test "sleeps for the time window when the limit is exceeded", %{sleep_spy: spy} do
      rate_limiter =
        :limited
        |> RateLimiter.new(limit: 2, per: 50)
        |> Map.put(:sleep, spy)

      results = Enum.map(1..5, fn x -> RateLimiter.call(rate_limiter, fn -> x end) end)
      assert results == [1, 2, 3, 4, 5]

      # Burst capacity is `limit`, so the first two calls are admitted at once
      # and each of the remaining three waits one emission interval (25ms). The
      # exact wait shrinks by however long the preceding sleep overran, so the
      # count is asserted exactly and the durations as an upper bound.
      sleeps = get_sleep_calls()
      assert length(sleeps) == 3
      assert Enum.all?(sleeps, &(&1 > 0 and &1 <= 25))
    end

    test "sleeps for exactly as long as the backend asks", %{sleep_spy: spy} do
      rate_limiter =
        :backend_controlled
        |> RateLimiter.new(limit: 1, per: 1_000, backend: {StubLimiter, [wait: 7]})
        |> Map.put(:sleep, spy)

      # The stub denies the first check for each call and allows the second, so
      # every call sleeps exactly once for the wait time the backend reported.
      StubLimiter.deny_next(2)
      assert RateLimiter.call(rate_limiter, fn -> :done end) == :done
      assert get_sleep_calls() == [7, 7]
    end

    test "never sleeps when wait: false", %{sleep_spy: spy} do
      rate_limiter =
        :no_wait
        |> RateLimiter.new(limit: 1, per: 1_000, wait: false, backend: {StubLimiter, [wait: 5]})
        |> Map.put(:sleep, spy)

      StubLimiter.deny_next(1)

      assert {RateLimiter, :rate_limited, 5} =
               RateLimiter.call(rate_limiter, fn -> flunk("should not have run") end)

      assert get_sleep_calls() == []
    end

    test "gives up once the wait budget would be exceeded", %{sleep_spy: spy} do
      rate_limiter =
        :short_budget
        |> RateLimiter.new(limit: 1, per: 1_000, wait: 10, backend: {StubLimiter, [wait: 100]})
        |> Map.put(:sleep, spy)

      StubLimiter.deny_next(1)

      assert {RateLimiter, :rate_limited, 100} =
               RateLimiter.call(rate_limiter, fn -> flunk("should not have run") end)

      assert get_sleep_calls() == []
    end

    test "waits when the budget allows it", %{sleep_spy: spy} do
      rate_limiter =
        :ample_budget
        |> RateLimiter.new(limit: 1, per: 1_000, wait: 1_000, backend: {StubLimiter, [wait: 5]})
        |> Map.put(:sleep, spy)

      StubLimiter.deny_next(2)

      assert RateLimiter.call(rate_limiter, fn -> :through end) == :through
      assert get_sleep_calls() == [5, 5]
    end

    test "the budget covers the whole call, not each individual sleep", %{sleep_spy: spy} do
      rate_limiter =
        :cumulative
        |> RateLimiter.new(limit: 1, per: 1_000, wait: 25, backend: {StubLimiter, [wait: 10]})
        |> Map.put(:sleep, spy)

      # Each sleep is well inside the budget, but the third would push the total
      # past it, so the call gives up rather than waiting indefinitely in
      # budget-sized increments.
      StubLimiter.deny_next(5)

      assert {RateLimiter, :rate_limited, 10} =
               RateLimiter.call(rate_limiter, fn -> flunk("should not have run") end)

      assert get_sleep_calls() == [10, 10]
    end

    defp init_sleep_spy(_context) do
      {:ok, _pid} = Agent.start_link(fn -> [] end, name: :sleep_spy)
      StubLimiter.reset()

      sleep_spy = fn sleep_time ->
        Agent.update(:sleep_spy, &[sleep_time | &1])
        Process.sleep(sleep_time)
      end

      [sleep_spy: sleep_spy]
    end

    defp get_sleep_calls, do: Enum.reverse(Agent.get(:sleep_spy, & &1))
  end
end
