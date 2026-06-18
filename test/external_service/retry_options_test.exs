defmodule ExternalService.RetryOptionsTest do
  use ExUnit.Case, async: true

  alias ExternalService.RetryOptions

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
