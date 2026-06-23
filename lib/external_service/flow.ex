# Compiled only when the optional `:flow` dependency is available. Consumers that
# don't add `:flow` to their deps simply won't have this module, and the rest of
# ExternalService never references `Flow`, so the dependency stays truly optional.
if Code.ensure_loaded?(Flow) do
  defmodule ExternalService.Flow do
    @moduledoc """
    [`Flow`](https://hexdocs.pm/flow)-based parallel processing of an enumerable
    (or another `Flow`) through guarded `ExternalService` calls.

    This is for the case where a guarded call is **one stage of a larger Flow
    pipeline** — partitioned, back-pressured processing with downstream
    `map`/`filter`/`reduce` stages. For a simple ordered, bounded-concurrency
    parallel map, prefer `ExternalService.call_async_stream/5`; `Flow` only earns
    its keep when you're building a pipeline.

    > #### Optional dependency {: .info}
    >
    > `ExternalService.Flow` exists only when the optional
    > [`:flow`](https://hex.pm/packages/flow) dependency is present. Add it to your
    > application's deps to use this module:
    >
    > ```elixir
    > {:flow, "~> 1.2"}
    > ```

    ## Example

        [order1, order2, order3]
        |> ExternalService.Flow.map(MyApp.Stripe, fn order ->
          case Stripe.charge(order) do
            {:error, %{status: s}} when s in 500..599 -> :retry
            other -> other
          end
        end)
        |> Flow.filter(&match?({:ok, _}, &1))
        |> Enum.to_list()

    `map/5` accepts either an enumerable (which it turns into a `Flow` source) or
    an existing `Flow`, and returns a `Flow` so you can keep composing.

    ## Semantics

    Each element is processed with `ExternalService.call/2,3`, so retries, the
    circuit breaker, rate limiting, and telemetry behave exactly as they do for a
    direct `call`. A few consequences worth knowing:

      * **Errors are elements.** Because `call/3` *returns* structured errors
        rather than raising them, a failed element comes through the Flow as the
        `{:error, %ExternalService.RetriesExhausted{}}` /
        `{:error, %CircuitBreakerOpen{}}` / `{:error, %ServiceNotStarted{}}` tuple
        that `call/3` returns — `filter`/`partition` on them downstream. (This
        module never uses `call!`, which would crash a Flow stage.)

      * **Unordered.** `Flow` partitions reorder elements. If you need results in
        input order, use `ExternalService.call_async_stream/5` instead.

      * **Rate-limit pacing.** Throttling blocks the worker (it sleeps and
        re-checks), which in a Flow naturally back-pressures upstream. The
        rate-limit bucket is global per service, so the configured limit is honored
        across all stages. Because a sleeping call stalls the rest of its demand
        batch, a small `:max_demand` gives smoother pacing under a rate limit.
    """

    alias ExternalService.RetryOptions

    @typedoc "An enumerable source or an existing `Flow` to continue."
    @type source :: Enumerable.t() | Flow.t()

    @typedoc "A function applied to each element, returning a retriable result."
    @type mapper :: (term() -> ExternalService.retriable_function_result())

    @doc """
    Maps each element of `source` through a guarded `ExternalService` call.

    `source` is either an enumerable (used as a `Flow` source via
    `Flow.from_enumerable/2`) or an existing `Flow` (whose stage configuration
    already applies, so `flow_opts` are ignored in that case). Returns a `Flow`.

    `retry_opts` are the same per-call retry options accepted by
    `ExternalService.call/3` (a keyword list of overrides merged onto the service's
    defaults, or a `t:ExternalService.RetryOptions.t/0` struct). `flow_opts` are
    passed straight to `Flow.from_enumerable/2` (for example `:stages`,
    `:min_demand`, `:max_demand`).
    """
    @spec map(source(), ExternalService.service(), mapper()) :: Flow.t()
    def map(source, service, fun) when is_function(fun, 1),
      do: map(source, service, [], fun, [])

    @spec map(source(), ExternalService.service(), RetryOptions.t() | keyword(), mapper()) ::
            Flow.t()
    def map(source, service, retry_opts, fun) when is_function(fun, 1),
      do: map(source, service, retry_opts, fun, [])

    @spec map(
            source(),
            ExternalService.service(),
            RetryOptions.t() | keyword(),
            mapper(),
            keyword()
          ) :: Flow.t()
    def map(source, service, retry_opts, fun, flow_opts) when is_function(fun, 1) do
      source
      |> to_flow(flow_opts)
      |> Flow.map(fn item ->
        ExternalService.call(service, retry_opts, fn -> fun.(item) end)
      end)
    end

    defp to_flow(source, _flow_opts) when is_struct(source, Flow), do: source
    defp to_flow(source, flow_opts), do: Flow.from_enumerable(source, flow_opts)
  end
end
