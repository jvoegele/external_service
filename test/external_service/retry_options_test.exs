defmodule ExternalService.RetryOptionsTest do
  use ExUnit.Case, async: true

  alias ExternalService.RetryOptions

  doctest ExternalService.RetryOptions

  describe "window/1" do
    test "adds up the delays a bounded configuration plans" do
      assert RetryOptions.window(base: 10, max_attempts: 5) == 150
      assert RetryOptions.window(base: 100, max_attempts: 5) == 1500
      assert RetryOptions.window(base: 100, max_attempts: 8) == 12_700
    end

    test "a single attempt waits for nothing" do
      assert RetryOptions.window(base: 100, max_attempts: 1) == 0
    end

    test "accepts a struct as well as a keyword list" do
      assert RetryOptions.window(%RetryOptions{base: 100, max_attempts: 5}) == 1500
    end

    test "the default configuration is 150ms" do
      assert RetryOptions.window([]) == 150
    end

    test ":cap bounds the runaway" do
      assert RetryOptions.window(base: 100, max_attempts: 10) == 51_100
      assert RetryOptions.window(base: 100, max_attempts: 10, cap: 1_000) == 6_500
      assert RetryOptions.window(base: 100, max_attempts: 10, cap: 2_000) == 11_100
    end

    test "an :expiry that is never reached does not bound the window" do
      # The worked example in the tuning guide: 1.5s of backoff against a 10s
      # budget, which is there to bound slow attempts rather than the waiting.
      assert RetryOptions.window(base: 100, cap: 2_000, max_attempts: 5, expiry: 10_000) == 1500
    end

    test "an :expiry reached first is what bounds the window" do
      assert RetryOptions.window(base: 10, max_attempts: 20, expiry: 1_000) == 1_000
    end

    test "an unbounded attempt count spends its :expiry exactly" do
      assert RetryOptions.window(base: 500, cap: 5_000, max_attempts: :infinity, expiry: 30_000) ==
               30_000
    end

    test "unbounded on both is :infinity" do
      assert RetryOptions.window(base: 500, max_attempts: :infinity) == :infinity

      assert RetryOptions.window(base: 500, max_attempts: :infinity, expiry: :infinity) ==
               :infinity
    end

    test "answers the configuration whose plan never terminates" do
      # Exponential backoff from a base of 0 yields zeros forever, so the plan is
      # infinite and cannot be summed. A real call busy-loops for the whole budget,
      # which is the number reported.
      assert RetryOptions.window(base: 0, max_attempts: :infinity, expiry: 1_000) == 1_000
    end

    test "agrees with summing the plan wherever the plan is finite" do
      for base <- [0, 10, 100, 500],
          max_attempts <- [1, 2, 5, 8],
          cap <- [nil, 200, 2_000],
          expiry <- [nil, 300, 10_000] do
        # `:cap` and `:expiry` have no default, so "unset" means absent rather
        # than nil — passing nil is a validation error.
        opts =
          [base: base, max_attempts: max_attempts, cap: cap, expiry: expiry]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> RetryOptions.new()

        assert RetryOptions.window(opts) == opts |> ExternalService.Retry.plan() |> Enum.sum(),
               "window/1 disagreed with the plan for #{inspect(opts)}"
      end
    end
  end

  describe "new/1" do
    test "returns a struct unchanged" do
      opts = %RetryOptions{max_attempts: 3}
      assert RetryOptions.new(opts) == opts
    end

    test "builds a struct from a keyword list, filling defaults" do
      assert %RetryOptions{backoff: :exponential, base: 10, max_attempts: 3} =
               RetryOptions.new(max_attempts: 3)
    end

    test "raises on invalid options" do
      assert_raise NimbleOptions.ValidationError, fn -> RetryOptions.new(backoff: :nope) end
    end

    test "accepts :infinity as an explicit statement that a bound is unbounded" do
      assert %RetryOptions{max_attempts: :infinity} = RetryOptions.new(max_attempts: :infinity)
      assert %RetryOptions{expiry: :infinity} = RetryOptions.new(expiry: :infinity)
    end

    test "accepts :retry_exceptions as either a module list or a predicate" do
      assert %RetryOptions{retry_exceptions: [RuntimeError]} =
               RetryOptions.new(retry_exceptions: [RuntimeError])

      predicate = &match?(%RuntimeError{}, &1)

      assert %RetryOptions{retry_exceptions: ^predicate} =
               RetryOptions.new(retry_exceptions: predicate)
    end

    test "rejects a :retry_exceptions value that is neither" do
      assert_raise NimbleOptions.ValidationError, fn ->
        RetryOptions.new(retry_exceptions: RuntimeError)
      end

      # A predicate has to take the exception, so arity matters.
      assert_raise NimbleOptions.ValidationError, fn ->
        RetryOptions.new(retry_exceptions: fn -> true end)
      end
    end

    test "rejects other atoms for the bounds" do
      assert_raise NimbleOptions.ValidationError, fn ->
        RetryOptions.new(max_attempts: :unlimited)
      end

      assert_raise NimbleOptions.ValidationError, fn -> RetryOptions.new(expiry: :forever) end
    end
  end

  describe "merge/2" do
    @base %RetryOptions{backoff: :linear, base: 100, factor: 2, max_attempts: 5}

    test "overrides only the keys present in the keyword list" do
      merged = RetryOptions.merge(@base, max_attempts: 2)

      assert merged.max_attempts == 2
      # Unspecified fields are inherited from the base.
      assert merged.backoff == :linear
      assert merged.base == 100
      assert merged.factor == 2
    end

    test "an empty keyword list leaves the base unchanged" do
      assert RetryOptions.merge(@base, []) == @base
    end

    test "a struct replaces the base entirely" do
      override = %RetryOptions{backoff: :exponential, base: 5}
      assert RetryOptions.merge(@base, override) == override
    end

    test "validates the override keys" do
      assert_raise NimbleOptions.ValidationError, fn ->
        RetryOptions.merge(@base, max_attempts: 0)
      end
    end
  end
end
