defmodule ExternalService.RetryPlanPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExternalService.Retry
  alias ExternalService.RetryOptions
  alias ExternalService.Test.Generators

  # Invariants of the delay plan, over options generated from the schema rather
  # than from a matrix someone maintains. `delay_stream_test.exs` still pins the
  # exact sequences — these say what is true of *every* configuration.

  property "the retry window is what the nominal plan adds up to" do
    # This replaces a hand-written 144-configuration matrix, which covered four
    # options and would not have covered a fifth.
    #
    # Nominal on both sides: `window/1` switches jitter off deliberately, so that
    # the same configuration always reports the same window, while `plan/1`
    # describes what a call would really do and keeps it. The property found that
    # difference on its sixth run, which is the distinction working rather than
    # failing.
    check all(retry <- Generators.bounded_retry_options()) do
      nominal = %RetryOptions{retry | jitter: false}

      assert RetryOptions.window(retry) == nominal |> Retry.plan() |> Enum.sum()
    end
  end

  property "with a count bound, jitter moves the delays but not the number of them" do
    # Only with a count bound. Against an `:expiry` the trim decides where the plan
    # ends, so jittered delays legitimately buy a different number of attempts —
    # which this property discovered by failing on its 93rd run.
    check all(retry <- Generators.count_bounded_retry_options()) do
      nominal = %RetryOptions{retry | jitter: false}
      jittered = %RetryOptions{retry | jitter: 0.25}

      assert Enum.count(Retry.plan(jittered)) == Enum.count(Retry.plan(nominal))
    end
  end

  property "a plan never overshoots its time budget" do
    check all(retry <- Generators.expiry_bounded_retry_options()) do
      assert retry |> Retry.plan() |> Enum.sum() <= retry.expiry
    end
  end

  property "a plan yields one delay fewer than its attempt count, at most" do
    check all(retry <- Generators.count_bounded_retry_options()) do
      assert retry |> Retry.plan() |> Enum.count() == retry.max_attempts - 1
    end
  end

  property "every delay is within the cap, and never negative" do
    check all(retry <- Generators.bounded_retry_options()) do
      delays = Retry.plan(retry)

      assert Enum.all?(delays, &(&1 >= 0))

      if retry.cap do
        assert Enum.all?(delays, &(&1 <= retry.cap)),
               "a delay exceeded cap: #{retry.cap} — #{inspect(Enum.take(delays, 10))}"
      end
    end
  end

  property "with no budget to spend, the plan and the live stream are the same" do
    # `plan/1` spends an `:expiry` against the delays, `delay_stream/1` against the
    # clock — so with a budget in play they are only expected to agree in the
    # trailing delay. With none, nothing distinguishes them.
    #
    # Nominal on both sides: each draws its own jitter, so a jittered comparison
    # would be asserting that two random sequences match.
    check all(retry <- Generators.count_bounded_retry_options()) do
      nominal = %RetryOptions{retry | jitter: false}

      assert Enum.to_list(Retry.plan(nominal)) == Enum.to_list(Retry.delay_stream(nominal))
    end
  end

  property "the window is nominal, so it does not move when jitter is on" do
    check all(retry <- Generators.bounded_retry_options()) do
      jittered = %RetryOptions{retry | jitter: 0.5}

      assert RetryOptions.window(jittered) ==
               RetryOptions.window(%RetryOptions{retry | jitter: false})
    end
  end

  property "merge/2 round-trips the keys it was given" do
    check all(
            base <- Generators.retry_options(),
            overrides <- Generators.options(RetryOptions.__schema__())
          ) do
      merged = RetryOptions.merge(base, overrides)

      for {key, value} <- overrides do
        assert Map.fetch!(merged, key) == value,
               "#{inspect(key)} did not survive the merge"
      end

      # Every key not overridden is inherited untouched.
      for {key, value} <- Map.from_struct(base),
          not Keyword.has_key?(overrides, key) do
        assert Map.fetch!(merged, key) == value
      end
    end
  end
end
