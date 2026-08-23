defmodule ExternalService.GeneratorsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExternalService.TestSupport.Generators

  # The property suite generates option values by walking the library's own
  # schemas. That only stays true if it keeps up with them — a generator that
  # quietly stops covering a new option is worse than none, because the suite still
  # looks like coverage. These are the tests that make it fail loudly instead.

  @schemas [
    {"retry", ExternalService.RetryOptions.__schema__()},
    {"circuit breaker", ExternalService.__schema__(:circuit_breaker)},
    {"rate limit", ExternalService.__schema__(:rate_limit)},
    {"concurrency", ExternalService.__schema__(:concurrency)},
    # The top-level schema is here so the guard is total: every option the library
    # declares anywhere is accounted for, including the ones whose values are
    # themselves schemas.
    {"start", ExternalService.__schema__(:start)}
  ]

  test "every option is either generated or declared un-generatable, with a reason" do
    for {name, schema} <- @schemas do
      covered = Generators.covered_keys(schema)
      declared = Map.keys(Generators.ungeneratable())
      unaccounted = Keyword.keys(schema) -- (covered ++ declared)

      assert unaccounted == [],
             """
             The #{name} schema has options the property suite does not generate and does \
             not say why: #{inspect(unaccounted)}.

             Either add a type to `ExternalService.TestSupport.Generators.from_type/2`, or add the \
             key to its `@ungeneratable` map with the reason it cannot be generated.
             """
    end
  end

  test "nothing is declared un-generatable that no schema has" do
    # The other direction: a reason left behind after an option was renamed or
    # removed reads as coverage that was considered and declined, when in fact
    # there is nothing there at all.
    all_keys = Enum.flat_map(@schemas, fn {_name, schema} -> Keyword.keys(schema) end)
    stale = Map.keys(Generators.ungeneratable()) -- all_keys

    assert stale == [],
           "`@ungeneratable` names options no schema has any more: #{inspect(stale)}"
  end

  property "generated retry options are always valid" do
    # Generating a value the library would reject would make every property a test
    # of the generator instead.
    check all(retry <- Generators.retry_options()) do
      assert %ExternalService.RetryOptions{} = retry
    end
  end

  property "generated circuit breaker options always start a service" do
    check all(breaker <- Generators.options(ExternalService.__schema__(:circuit_breaker))) do
      service = :"generated-#{:erlang.unique_integer([:positive])}"

      # `:tolerate` and `:melt` can combine into a configuration that is rejected
      # rather than merely unwise, which is `validate_melt_bound!/3` doing its job.
      assert :ok =
               ExternalService.start(service,
                 circuit_breaker: breaker,
                 retry: [max_attempts: 3]
               )

      ExternalService.stop(service)
    end
  end

  test "the boundaries a type declares are actually generated" do
    # The point of deriving from the schema rather than hand-writing ranges: the
    # edges come from the declaration. If this stops holding, the generators are
    # sampling the middle of the space and calling it coverage.
    sample = Enum.take(Generators.retry_options(), 400)

    assert Enum.any?(sample, &(&1.max_attempts == 1)), "the minimum :max_attempts never appeared"
    assert Enum.any?(sample, &(&1.max_attempts == :infinity)), ":infinity never appeared"
    assert Enum.any?(sample, &(&1.base == 0)), "the minimum :base never appeared"
    assert Enum.any?(sample, &is_nil(&1.cap)), "an unset :cap never appeared"
    assert Enum.any?(sample, &is_integer(&1.cap)), "a set :cap never appeared"
    assert Enum.any?(sample, &(&1.expiry == :infinity)), "an :infinity :expiry never appeared"
  end
end
