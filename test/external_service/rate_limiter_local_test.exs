defmodule ExternalService.RateLimiter.LocalTest do
  @moduledoc """
  Covers the default rate limiter backend's token-bucket behavior: burst
  capacity, pacing, the accuracy of the reported wait, and correctness when many
  processes meter against the same service at once.
  """

  use ExUnit.Case

  alias ExternalService.RateLimiter.Local

  @moduletag capture_log: true

  # Long enough that the bucket does not refill during a test unless the test
  # deliberately waits for it.
  @wide_window :timer.minutes(1)

  describe "burst capacity" do
    test "admits exactly :limit calls before throttling" do
      {:ok, config} = Local.init(:burst, limit: 5, per: @wide_window)

      assert Enum.map(1..5, fn _ -> Local.check(:burst, config) end) == List.duplicate(:ok, 5)
      assert {:wait, _} = Local.check(:burst, config)
    end

    test "a limit of one admits a single call per window" do
      {:ok, config} = Local.init(:single, limit: 1, per: @wide_window)

      assert Local.check(:single, config) == :ok
      assert {:wait, _} = Local.check(:single, config)
    end
  end

  describe "pacing" do
    test "reports a wait no longer than one emission interval once the burst is spent" do
      # 10 calls per 100ms is one call per 10ms.
      {:ok, config} = Local.init(:paced, limit: 10, per: 100)
      Enum.each(1..10, fn _ -> Local.check(:paced, config) end)

      assert {:wait, wait} = Local.check(:paced, config)
      assert wait > 0 and wait <= 10
    end

    test "admits another call once the reported wait has elapsed" do
      {:ok, config} = Local.init(:refill, limit: 2, per: 50)
      assert Local.check(:refill, config) == :ok
      assert Local.check(:refill, config) == :ok

      assert {:wait, wait} = Local.check(:refill, config)
      Process.sleep(wait)

      assert Local.check(:refill, config) == :ok
    end

    test "does not allow a fresh full burst immediately after a window elapses" do
      # The bursty failure mode of a fixed window: with `limit` calls at the end
      # of one window and `limit` more at the start of the next, twice the limit
      # lands back to back. A token bucket refills one call at a time instead.
      {:ok, config} = Local.init(:no_double_burst, limit: 4, per: 40)
      Enum.each(1..4, fn _ -> Local.check(:no_double_burst, config) end)

      # Wait out a full window; the bucket has refilled, but only to `limit`.
      Process.sleep(40)

      admitted =
        1..8
        |> Enum.map(fn _ -> Local.check(:no_double_burst, config) end)
        |> Enum.count(&(&1 == :ok))

      assert admitted <= 4
    end
  end

  describe "concurrency" do
    test "admits exactly :limit calls when many processes meter at once" do
      limit = 50
      {:ok, config} = Local.init(:concurrent, limit: limit, per: @wide_window)

      admitted =
        1..500
        |> Task.async_stream(fn _ -> Local.check(:concurrent, config) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.count(fn {:ok, result} -> result == :ok end)

      # The compare-and-exchange retry loop must neither admit more than the
      # limit (over-admitting) nor lose admissions to a lost update.
      assert admitted == limit
    end
  end

  describe "isolation" do
    test "each service meters against its own bucket" do
      {:ok, one} = Local.init(:service_one, limit: 1, per: @wide_window)
      {:ok, two} = Local.init(:service_two, limit: 1, per: @wide_window)

      assert Local.check(:service_one, one) == :ok
      assert {:wait, _} = Local.check(:service_one, one)

      assert Local.check(:service_two, two) == :ok
    end
  end
end
