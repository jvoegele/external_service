defmodule ExternalService.TestSupport.Generators do
  @moduledoc false

  # `StreamData` generators derived from the library's own option schemas.
  #
  # The point is not the generation — hand-written generators would produce much
  # the same values. It is that a key added to a schema is either generated here or
  # fails `generators_test.exs`, which asserts every key is accounted for. A
  # property suite that quietly stops keeping up with the options is worse than
  # none, because it still looks like coverage.
  #
  # This is the portable half of Bond's `probe_contract/2`: read the declared
  # contract and probe the boundaries it implies, rather than the boundaries
  # someone remembered. A `:pos_integer` is generated with `1` mixed in, an
  # `{:or, [_, {:in, [:infinity]}]}` with `:infinity` mixed in, and so on — the
  # edges come from the type declaration.

  import StreamData

  # Options whose values cannot be generated meaningfully, each with the reason.
  # `generators_test.exs` reads this, so an unsupported option has to be declared
  # here rather than silently skipped.
  @ungeneratable %{
    retry_on: "a predicate; generating one would test StreamData, not the library",
    retry_exceptions: "a module list or predicate; same",
    backend: "a module, and swapping backends is what backend_test.exs is for",
    sleep_function: "a function, supplied by whichever test needs it",
    fault_injection: "randomises the breaker, which would make every property flaky",
    circuit_breaker: "a nested schema, generated through options/1 on that schema directly",
    rate_limit: "a nested schema, generated through options/1 on that schema directly",
    concurrency: "a nested schema, generated through options/1 on that schema directly",
    retry: "a nested schema, generated through options/1 on that schema directly"
  }

  # A schema declares a *type*, not a magnitude, and `:pos_integer` means something
  # very different for `:max_attempts` than for `:expiry`. Derivation gives the
  # shape — which branches an `{:or, …}` has, where its boundaries are — and these
  # give the scale. A key missing from here still generates, just over the default
  # range; `generators_test.exs` is what makes sure it generates at all.
  @ranges %{
    max_attempts: 1..8,
    base: 0..500,
    factor: 1..10,
    cap: 1..5_000,
    expiry: 1..30_000,
    tolerate: 1..25,
    within: 1..120_000,
    reset: 1..120_000,
    limit: 1..100,
    per: 1..60_000,
    wait: 0..10_000,
    reclaim_after: 1..60_000
  }

  @doc "Options this module deliberately does not generate, and why."
  def ungeneratable, do: @ungeneratable

  @doc "The keys of `schema` this module produces values for."
  def covered_keys(schema) do
    for {key, spec} <- schema,
        not Map.has_key?(@ungeneratable, key),
        from_type(spec[:type], key) != :unsupported,
        do: key
  end

  @doc """
  A generator of valid keyword lists for `schema`, drawing each key from its
  declared type. Keys without a default are sometimes omitted, since "unset" is a
  distinct state for `:cap` and `:expiry`.
  """
  def options(schema) do
    schema
    |> Enum.reject(fn {key, _spec} -> Map.has_key?(@ungeneratable, key) end)
    |> Enum.map(fn {key, spec} -> {key, spec, from_type(spec[:type], key)} end)
    |> Enum.reject(fn {_key, _spec, generator} -> generator == :unsupported end)
    |> Enum.map(fn {key, spec, generator} ->
      if Keyword.has_key?(spec, :default) or spec[:required] do
        map(generator, &{key, &1})
      else
        # An option with no default has an "unset" state that is not any of its
        # values — and for `:cap` and `:expiry` that state is the interesting one.
        one_of([constant(:__unset__), map(generator, &{key, &1})])
      end
    end)
    |> fixed_list()
    |> map(&Enum.reject(&1, fn value -> value == :__unset__ end))
  end

  @doc "Retry options as a validated struct."
  def retry_options do
    map(options(ExternalService.RetryOptions.__schema__()), &ExternalService.RetryOptions.new/1)
  end

  @doc """
  Retry options whose plan is finite and short enough to enumerate.

  Filtering, because "finite" is a property of the whole combination rather than
  of any one key.
  """
  def bounded_retry_options do
    filter(retry_options(), &enumerable?/1, 50)
  end

  @doc """
  Retry options that always carry a time budget.

  Constructed rather than filtered: an `:expiry` is generated in roughly half of
  all options, so a property that only wants budgeted ones would throw away half
  its generation space and eventually give up.
  """
  def expiry_bounded_retry_options do
    {options(ExternalService.RetryOptions.__schema__()), integer(1..30_000)}
    |> tuple()
    |> map(fn {opts, expiry} ->
      ExternalService.RetryOptions.new(Keyword.put(opts, :expiry, expiry))
    end)
    |> filter(&enumerable?/1, 50)
  end

  @doc """
  Retry options bounded by a count and by nothing else.

  The plan is then exactly `max_attempts - 1` delays, which is what properties
  about the shape of a sequence need — with an `:expiry` in play the trim decides
  where it ends, and that is a different property.
  """
  def count_bounded_retry_options do
    {options(ExternalService.RetryOptions.__schema__()), integer(1..8)}
    |> tuple()
    |> map(fn {opts, max_attempts} ->
      opts
      |> Keyword.delete(:expiry)
      |> Keyword.put(:max_attempts, max_attempts)
      |> ExternalService.RetryOptions.new()
    end)
  end

  # A plan a property can enumerate: finite, and short enough to afford. Both
  # halves are needed and it is easy to apply only one — an `:expiry` bounds a plan
  # in time without bounding it in count, so a budgeted configuration can still
  # describe an infinite sequence of zero-length delays.
  defp enumerable?(retry), do: finite_plan?(retry) and affordable?(retry)

  # A count bound always terminates the plan.
  defp finite_plan?(%{max_attempts: max_attempts}) when is_integer(max_attempts), do: true

  # Without one, only a time budget can — and only if the delays actually spend it.
  defp finite_plan?(%{expiry: expiry}) when expiry in [nil, :infinity], do: false

  # Exponential backoff from a base of 0 yields zeros forever and never spends
  # anything, so its plan is infinite. `Retry.plan/1` documents this, and
  # `RetryOptions.window/1` answers it without enumerating.
  defp finite_plan?(%{backoff: :exponential, base: 0}), do: false

  defp finite_plan?(_retry), do: true

  # Finite is not the same as short. `cap: 1` against a thirty-second budget
  # describes thirty thousand delays, and the expiry trim is quadratic in their
  # number — so a property that enumerates whole plans has to decline that one.
  # Conservative on purpose: rejecting a plan costs coverage, and enumerating it
  # costs the suite.
  @affordable_delays 64

  defp affordable?(%{max_attempts: max_attempts}) when is_integer(max_attempts),
    do: max_attempts <= @affordable_delays

  defp affordable?(%{expiry: expiry, base: base, cap: cap}) when is_integer(expiry) do
    # Once the backoff reaches its cap the delays stop growing, so the cap is what
    # sets the length of the tail; without one, growth keeps the plan short.
    step = cap || base
    step > 0 and div(expiry, step) <= @affordable_delays
  end

  defp affordable?(_retry), do: false

  # Boundaries come from the declared type. `:pos_integer` gets its minimum mixed
  # in, `:non_neg_integer` gets zero, an `{:or, …}` gets each of its branches — so
  # the edges are probed deliberately rather than waited for.
  defp from_type(:pos_integer, key), do: bounded(key, 1)
  defp from_type(:non_neg_integer, key), do: bounded(key, 0)
  defp from_type(:boolean, _key), do: boolean()
  defp from_type(:float, _key), do: float(min: 0.0, max: 1.0)
  defp from_type({:in, values}, _key), do: member_of(values)
  defp from_type({:or, types}, key), do: types |> Enum.map(&from_type(&1, key)) |> one_of()
  defp from_type({:list, :atom}, _key), do: constant([])
  defp from_type(_other, _key), do: :unsupported

  defp bounded(key, minimum) do
    range = Map.get(@ranges, key, minimum..2_000)
    frequency([{1, constant(range.first)}, {4, integer(range)}])
  end
end
