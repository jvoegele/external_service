defmodule ExternalService.Decorator do
  @moduledoc """
  Decorator-based annotations for marking functions as external-service calls.

  This is a thin convenience layer over the [module front door](`ExternalService`):
  instead of wrapping a function body in `call fn -> ... end` by hand, you annotate
  the function with `@decorate external_call(service)` and write the body directly.

  `use ExternalService.Decorator` brings the decorators into scope (built on the
  [`decorator`](https://hex.pm/packages/decorator) library):

      defmodule MyApp.Payments do
        use ExternalService.Decorator

        @decorate external_call(MyApp.Stripe)
        def charge(params) do
          case Stripe.charge(params) do
            {:error, %{status: s}} when s in 500..599 -> :retry
            other -> other
          end
        end
      end

  The annotated function behaves exactly as if its body were passed to
  `ExternalService.call/2`: it returns the body's value on success, or a structured
  error (`ExternalService.RetriesExhausted` / `ExternalService.CircuitBreakerOpen` /
  `ExternalService.ServiceNotStarted`) on failure.

  The `service` argument is any term identifying a service that has been started
  (via `ExternalService.start/2` or `use ExternalService`). It need not be the
  module the decorated function lives in, so a single module can decorate calls to
  several services.

  ## The retry protocol still applies

  The decorated body *is* the retriable function, so it drives retries the same way
  the body of `call fn -> ... end` would — by returning `:retry` / `{:retry, reason}`,
  or by configuring a retry option. A body that just returns the underlying client's
  result is **not** retried unless you tell it how. Two ways to do that:

    * return `:retry` / `{:retry, reason}` from the body (as above), or
    * pass per-call retry options as the second decorator argument, for example a
      `:retry_on` predicate that decides from the return value — handy when the body
      is an unmodified client call:

          @decorate external_call(MyApp.Stripe, retry_on: &match?({:error, %{status: 500}}, &1))
          def charge(params), do: Stripe.charge(params)

  The second argument is the same per-call retry options accepted by
  `ExternalService.call/3` (a keyword list of overrides merged onto the service's
  defaults, or a `t:ExternalService.RetryOptions.t/0` struct).

  ## Raising variant

  `external_call!` mirrors `ExternalService.call!/2,3`: it raises the structured
  error instead of returning it.

      @decorate external_call!(MyApp.Stripe)
      def capture(id), do: Stripe.capture(id)

  ## Decorators

    * `external_call(service)` / `external_call(service, retry_opts)`
    * `external_call!(service)` / `external_call!(service, retry_opts)`
  """

  use Decorator.Define,
    external_call: 1,
    external_call: 2,
    external_call!: 1,
    external_call!: 2

  @doc "Wraps the function body in `ExternalService.call/2`."
  def external_call(service, body, _context) do
    quote do
      ExternalService.call(unquote(service), fn -> unquote(body) end)
    end
  end

  @doc "Wraps the function body in `ExternalService.call/3` with per-call retry options."
  def external_call(service, retry_opts, body, _context) do
    quote do
      ExternalService.call(unquote(service), unquote(retry_opts), fn -> unquote(body) end)
    end
  end

  @doc "Wraps the function body in `ExternalService.call!/2`."
  def external_call!(service, body, _context) do
    quote do
      ExternalService.call!(unquote(service), fn -> unquote(body) end)
    end
  end

  @doc "Wraps the function body in `ExternalService.call!/3` with per-call retry options."
  def external_call!(service, retry_opts, body, _context) do
    quote do
      ExternalService.call!(unquote(service), unquote(retry_opts), fn -> unquote(body) end)
    end
  end
end
