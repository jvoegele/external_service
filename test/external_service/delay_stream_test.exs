defmodule ExternalService.DelayStreamTest do
  use ExUnit.Case, async: true

  alias ExternalService.Retry
  alias ExternalService.RetryOptions

  # Characterization tests for the delays the retry loop actually sleeps for.
  #
  # These exist to make replacing the ElixirRetry dependency (issue #69) a
  # verifiable refactor rather than a hopeful one. Delay sequences are observable
  # behavior that no error reports on: a subtly different `:exponential` changes
  # the timing of every user's retries silently. These assert on the sequence
  # itself rather than on elapsed time, so they are fast, deterministic, and
  # precise about what changed.
  #
  # If one fails after a change to the delay streams, that change moved observable
  # behavior. Decide whether that was intended — do not re-baseline the assertion
  # to make it pass.

  defp delays(opts, count) do
    opts |> unbounded() |> RetryOptions.new() |> Retry.delay_stream() |> Enum.take(count)
  end

  defp all_delays(opts) do
    opts |> unbounded() |> RetryOptions.new() |> Retry.delay_stream() |> Enum.to_list()
  end

  # Most of these tests are about the shape of the backoff rather than about where
  # it stops, so they opt out of the `:max_attempts` default — which would
  # otherwise truncate every sequence to four delays. Tests that set the bound
  # themselves are unaffected.
  defp unbounded(opts), do: Keyword.put_new(opts, :max_attempts, :infinity)

  describe "backoff strategies" do
    test "exponential doubles the base delay" do
      assert delays([backoff: :exponential, base: 10], 6) == [10, 20, 40, 80, 160, 320]
      assert delays([backoff: :exponential, base: 100], 5) == [100, 200, 400, 800, 1600]
    end

    test "exponential ignores :factor, which only applies to linear backoff" do
      assert delays([backoff: :exponential, base: 10, factor: 5], 5) ==
               delays([backoff: :exponential, base: 10], 5)
    end

    test "linear adds :factor to the base delay each time" do
      assert delays([backoff: :linear, base: 10, factor: 1], 6) == [10, 11, 12, 13, 14, 15]
      assert delays([backoff: :linear, base: 100, factor: 50], 5) == [100, 150, 200, 250, 300]
    end

    test "a base of 0 delays not at all" do
      assert delays([backoff: :exponential, base: 0], 4) == [0, 0, 0, 0]
      assert delays([backoff: :linear, base: 0, factor: 1], 4) == [0, 1, 2, 3]
    end

    test "the default backoff is exponential from a base of 10" do
      assert delays([], 4) == [10, 20, 40, 80]
    end

    test "the defaults on their own describe five attempts across 150ms" do
      # Not routed through `unbounded/1`: this is the default configuration exactly
      # as a service that configures nothing would get it.
      delays = [] |> RetryOptions.new() |> Retry.delay_stream() |> Enum.to_list()

      assert delays == [10, 20, 40, 80]
      assert Enum.sum(delays) == 150
    end
  end

  describe ":cap" do
    test "clamps each delay without ending the stream" do
      assert delays([backoff: :exponential, base: 10, cap: 50], 6) == [10, 20, 40, 50, 50, 50]
    end
  end

  describe ":max_attempts" do
    test "yields one delay fewer than the attempt count" do
      # `max_attempts` counts the initial attempt, which has no delay before it.
      assert all_delays(backoff: :exponential, base: 10, max_attempts: 4) == [10, 20, 40]
    end

    test "a single attempt means no retries at all" do
      assert all_delays(backoff: :exponential, base: 10, max_attempts: 1) == []
    end

    test "an unset or :infinity bound does not limit the stream" do
      unbounded = delays([backoff: :exponential, base: 10], 3)

      assert delays([backoff: :exponential, base: 10, max_attempts: :infinity], 3) == unbounded
    end
  end

  describe ":expiry" do
    # These tests never sleep, so the clock barely advances while the stream is
    # drawn and each `left` is computed against almost the whole budget. What they
    # pin is the stream's *shape*; the wall-clock behavior a real call sees — the
    # budget being spent but not overshot — is asserted in `external_service_test.exs`.

    test "trims the last delay to what is left of the budget, then ends" do
      result = all_delays(backoff: :exponential, base: 10, expiry: 1000)

      # The preferred delays are used while they fit...
      assert [10, 20, 40, 80, 160, 320, 640 | rest] = result
      # ...and the one that would overshoot is replaced by the remaining budget.
      assert [last] = rest
      assert last > 900 and last <= 1000
    end

    test "a small budget is trimmed to fit rather than rounded up" do
      # Before #70 both of these were `[100]`: the final delay was floored at 100ms,
      # so a budget under that cost 100ms and bought an extra attempt.
      #
      # The trailing delay is what is left of the budget *measured when it is asked
      # for*, so it is bounded by the budget rather than equal to it — time spent
      # drawing the stream comes off it. These therefore assert a bound. (Asserting
      # `== 50` passed 25 local runs and failed on a slower CI runner at 49.)
      assert [10, 20, 40, last] = all_delays(backoff: :exponential, base: 10, expiry: 50)
      assert last <= 50

      # A 1ms budget yields `[1]`, or `[]` if a millisecond has already gone; either
      # way nothing is floored up to 100.
      assert [] == Enum.filter(all_delays(backoff: :exponential, base: 10, expiry: 1), &(&1 > 1))
    end

    test "an unset or :infinity budget does not limit the stream" do
      unbounded = delays([backoff: :exponential, base: 10], 3)

      assert delays([backoff: :exponential, base: 10, expiry: :infinity], 3) == unbounded
    end
  end

  describe ":jitter" do
    # Jitter is random, so these pin the bounds it can produce and the fact that it
    # varies at all, rather than any particular sequence.

    test "true spreads each delay by +/- 10%" do
      samples =
        Enum.map(1..200, fn _ -> hd(delays([backoff: :linear, base: 100, jitter: true], 1)) end)

      # `randomize/2` shifts by `:rand.uniform(2 * max_delta) - max_delta`, which for
      # a delay of 100 spans -9..10 rather than a symmetric -10..10.
      assert Enum.all?(samples, &(&1 >= 91 and &1 <= 110))
      assert length(Enum.uniq(samples)) > 1
    end

    test "a float spreads each delay by that proportion" do
      samples =
        Enum.map(1..200, fn _ -> hd(delays([backoff: :linear, base: 100, jitter: 0.25], 1)) end)

      assert Enum.all?(samples, &(&1 >= 76 and &1 <= 125))
      assert length(Enum.uniq(samples)) > 1
    end

    test "never produces a negative delay" do
      samples =
        Enum.map(1..200, fn _ -> hd(delays([backoff: :exponential, base: 0, jitter: true], 1)) end)

      assert Enum.all?(samples, &(&1 == 0))
    end

    test "false leaves the delays exactly as they are" do
      assert delays([backoff: :exponential, base: 10, jitter: false], 4) == [10, 20, 40, 80]
    end
  end

  describe "combinations" do
    test ":cap applies before :max_attempts truncates" do
      assert all_delays(backoff: :exponential, base: 10, cap: 50, max_attempts: 5) ==
               [10, 20, 40, 50]
    end

    test ":cap bounds jittered delays too, because jitter is applied first" do
      samples =
        Enum.map(1..200, fn _ ->
          hd(delays([backoff: :linear, base: 100, jitter: 0.25, cap: 110], 1))
        end)

      assert Enum.all?(samples, &(&1 <= 110))
      # The cap only clips the top: values below it still vary.
      assert length(Enum.uniq(samples)) > 1
    end

    test "the whole set of options composes into one finite stream" do
      result =
        all_delays(
          backoff: :exponential,
          base: 100,
          cap: 400,
          max_attempts: 6,
          expiry: 10_000,
          jitter: false
        )

      assert result == [100, 200, 400, 400, 400]
    end
  end
end
