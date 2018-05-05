defmodule ExternalService.RateLimitTest do
  use ExUnit.Case
  alias ExternalService.RateLimit

  describe "new/2" do
    test "calling with nil makes an empty RateLimit struct" do
      assert RateLimit.new(:foo, nil) == %RateLimit{}
    end

    test "with map" do
      rate_limit = RateLimit.new(:foo, %{time_window: 100, limit: 10})
      assert %RateLimit{limit: 10, time_window: 100} = rate_limit
    end

    test "with keyword list" do
      rate_limit = RateLimit.new(:foo, time_window: 100, limit: 10)
      assert %RateLimit{limit: 10, time_window: 100} = rate_limit
    end

    test "with tuple" do
      rate_limit = RateLimit.new(:foo, {10, 100})
      assert %RateLimit{limit: 10, time_window: 100} = rate_limit
    end

    test "enforces valid arguments" do
      assert_raise(ArgumentError, fn -> RateLimit.new(:foo, {0, 100}) end)
      assert_raise(ArgumentError, fn -> RateLimit.new(:foo, {10, 0}) end)
    end
  end

  describe "call/2" do
    setup [:init_sleep_spy]

    test "with no rate limit", %{sleep_spy: spy} do
      rate_limit = RateLimit.new(:unlimited, nil)
      RateLimit.call(%{rate_limit | sleep: spy}, fn -> :ok end)
      assert get_sleep_calls() == []
    end

    test "sleeps for time window when limit exceeded", %{sleep_spy: spy} do
      rate_limit =
        :limited
        |> RateLimit.new({2, 50})
        |> Map.put(:sleep, spy)

      Enum.each(1..5, fn _ -> RateLimit.call(rate_limit, fn -> :noop end) end)
      assert get_sleep_calls() == [50, 50]
    end

    defp init_sleep_spy(_context) do
      {:ok, _pid} = Agent.start_link(fn -> [] end, name: :sleep_spy)

      sleep_spy = fn sleep_time ->
        Agent.update(:sleep_spy, &[sleep_time | &1])
        Process.sleep(sleep_time)
      end

      [sleep_spy: sleep_spy]
    end

    defp get_sleep_calls, do: Enum.reverse(Agent.get(:sleep_spy, & &1))
  end
end
