defmodule ExternalService.MergeConfigTest do
  use ExUnit.Case, async: true

  alias ExternalService.RetryOptions

  # Characterization tests for the deep merge that combines child-spec overrides
  # with the options given to `use ExternalService`.
  #
  # These were written against `DeepMerge.deep_merge/2` before that dependency was
  # replaced, and every assertion below held for it unchanged. The rules are
  # subtler than "recurse into keyword lists" — in particular an empty override
  # list means two different things depending on the shape of the original — so
  # they are pinned rather than trusted.

  defp merge(original, override), do: ExternalService.__merge_config__(original, override)

  describe "merging option structures" do
    test "keys present on only one side are kept" do
      assert merge([circuit_breaker: [tolerate: 5]], retry: [max_attempts: 3]) ==
               [circuit_breaker: [tolerate: 5], retry: [max_attempts: 3]]
    end

    test "nested keyword lists merge rather than replace" do
      assert merge([circuit_breaker: [tolerate: 5]], circuit_breaker: [within: 99]) ==
               [circuit_breaker: [tolerate: 5, within: 99]]
    end

    test "the override wins on a conflicting leaf" do
      assert merge([circuit_breaker: [tolerate: 5]], circuit_breaker: [tolerate: 9]) ==
               [circuit_breaker: [tolerate: 9]]
    end

    test "recursion is not limited to one level" do
      assert merge([a: [b: [c: 1, d: 2]]], a: [b: [c: 9]]) == [a: [b: [d: 2, c: 9]]]
    end
  end

  describe "empty override lists" do
    test "an empty override leaves a keyword-shaped original alone" do
      # So `start_link(circuit_breaker: [])` is a no-op rather than a reset. This
      # is the rule that is easiest to get wrong when hand-rolling the merge.
      assert merge([circuit_breaker: [tolerate: 5]], circuit_breaker: []) ==
               [circuit_breaker: [tolerate: 5]]
    end

    test "an empty override at the top level changes nothing" do
      assert merge([circuit_breaker: [tolerate: 5]], []) == [circuit_breaker: [tolerate: 5]]
    end

    test "but an empty override does clear a list that is not keyword-shaped" do
      # The two rules interact: `[RuntimeError]` is not keyword-shaped, so the
      # generic "override wins" applies and the empty list is taken literally.
      assert merge([retry: [retry_exceptions: [RuntimeError]]], retry: [retry_exceptions: []]) ==
               [retry: [retry_exceptions: []]]
    end
  end

  describe "values that are replaced wholesale" do
    test "a struct override replaces a keyword list" do
      assert [retry: %RetryOptions{max_attempts: 9}] =
               merge([retry: [max_attempts: 3]], retry: %RetryOptions{max_attempts: 9})
    end

    test "a keyword list override replaces a struct" do
      # A `RetryOptions` struct is a complete set of options, so it is replaced
      # rather than merged into — matching `RetryOptions.merge/2`.
      assert merge([retry: %RetryOptions{max_attempts: 3}], retry: [max_attempts: 9]) ==
               [retry: [max_attempts: 9]]
    end

    test "plain lists replace rather than concatenate" do
      assert merge(
               [retry: [retry_exceptions: [RuntimeError]]],
               retry: [retry_exceptions: [ArgumentError]]
             ) == [retry: [retry_exceptions: [ArgumentError]]]
    end

    test "tuples replace" do
      assert merge([rate_limit: [backend: {A, []}]], rate_limit: [backend: {B, [a: 1]}]) ==
               [rate_limit: [backend: {B, [a: 1]}]]
    end

    test "scalars replace, in either direction" do
      assert merge([sleep_function: :old], sleep_function: :new) == [sleep_function: :new]
      assert merge([retry: [max_attempts: 3]], retry: :nope) == [retry: :nope]
      assert merge([retry: :nope], retry: [max_attempts: 3]) == [retry: [max_attempts: 3]]
    end

    test "functions replace" do
      old = fn _ -> :old end
      new = fn _ -> :new end

      assert [sleep_function: merged] = merge([sleep_function: old], sleep_function: new)
      assert merged.(1) == :new
    end
  end
end
