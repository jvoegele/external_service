defmodule ExternalService.RateLimiter.Local do
  @moduledoc """
  The default rate limiter backend: a node-local token bucket.

  You get this without configuring anything. It allows a burst of up to `:limit`
  calls and then paces the rest at one call per `:per / :limit`, refilling one
  call at a time rather than handing out a fresh full burst at each window
  boundary.

  It is **node-local**: counters live in this node's memory, so N nodes running
  the same service each enforce the limit separately and the external service can
  see up to N times the configured rate. For a limit shared across a cluster, use
  `ExternalService.RateLimiter.Hammer`.

  State is a single `:atomics` slot per service, so this backend needs no owning
  process, no supervision tree, and no dependency.
  """

  # The algorithm is GCRA (the generic cell rate algorithm), the standard
  # formulation of a leaky bucket used as a meter. One number is stored: the
  # "theoretical arrival time" (TAT) at which the bucket would next be empty.
  # A call is admitted when `TAT - burst_allowance <= now`, and admitting it
  # pushes TAT forward by one emission interval. That yields a burst capacity of
  # exactly `:limit` calls followed by smooth pacing at `:limit` per `:per`,
  # rather than the bursty "up to twice the limit across a window boundary"
  # behavior of a fixed window.
  #
  # Concurrency is handled with a compare-and-exchange retry loop rather than a
  # lock, so concurrent callers can never admit more than the limit allows.
  #
  # Times are tracked in microseconds so that an emission interval that does not
  # divide evenly into milliseconds (say 100 calls per second) does not drift.

  @behaviour ExternalService.RateLimiter

  @impl true
  def init(_service, options) do
    limit = Keyword.fetch!(options, :limit)
    window = Keyword.fetch!(options, :per) * 1_000

    ref = :atomics.new(1, signed: true)
    # Seeded with the current time rather than zero: the monotonic clock may be
    # negative, and a zero TAT would then read as far in the *future*, throttling
    # the first calls.
    :atomics.put(ref, 1, now())

    config = %{
      ref: ref,
      # Microseconds each admitted call pushes the TAT forward.
      interval: div(window, limit),
      # How far ahead of `now` the TAT may run before calls are refused. One
      # full window's worth gives a burst capacity of exactly `limit`.
      burst: window
    }

    {:ok, config}
  end

  @impl true
  def check(_service, %{ref: ref, interval: interval, burst: burst}) do
    admit(ref, interval, burst, now())
  end

  @impl true
  def peek(_service, %{ref: ref, interval: interval, burst: burst}) do
    # The same arithmetic as `admit/4`, minus the compare-and-exchange that
    # would move the bucket forward. Reading a single atomics slot is already
    # atomic, so no retry loop is needed.
    now = now()
    admit_at = max(:atomics.get(ref, 1), now) + interval - burst

    if admit_at > now, do: {:wait, to_milliseconds(admit_at - now)}, else: :ok
  end

  defp admit(ref, interval, burst, now) do
    tat = :atomics.get(ref, 1)
    # A TAT in the past means the bucket has drained; the call is metered from
    # now rather than from the stale timestamp.
    next_tat = max(tat, now) + interval
    admit_at = next_tat - burst

    if admit_at > now do
      {:wait, to_milliseconds(admit_at - now)}
    else
      case :atomics.compare_exchange(ref, 1, tat, next_tat) do
        :ok -> :ok
        # Another process advanced the TAT first, so this decision was made
        # against a stale value. Recompute against the value it actually holds.
        _current -> admit(ref, interval, burst, now)
      end
    end
  end

  defp now, do: System.monotonic_time(:microsecond)

  # Always at least one millisecond, so that a caller waiting on a sub-millisecond
  # remainder sleeps rather than spinning.
  defp to_milliseconds(microseconds), do: max(1, ceil(microseconds / 1_000))
end
