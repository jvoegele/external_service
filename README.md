# ExternalService

An Elixir library for safely using external services using customizable retry logic, automatic rate limiting, and the circuit breaker pattern.

## Overview

`ExternalService` is, in essence, the combination of two techniques: retrying individual requests that have failed and preventing cascading failures with circuit breakers. The basic approach to using `ExternalService` is to wrap all usages of any external services in an Elixir function and pass this function to the `ExternalService.call` function, together with some options that control the retry mechanism. By doing so, `ExternalService` can manage calls to the external API that you’re using, and apply retry logic to individual calls while ensuring that your application is protected from outages or other problems with the external API by using “circuit breakers” (described in more detail below).

In addition to the `call` function, `ExternalService` also provides a `call_async` function, which uses an Elixir Task to call the external service asynchronously, and a `call_async_stream` function, which makes multiple calls to the external service in parallel.

Both of these functions apply the same retry and “circuit breaker” mechanisms as the regular call function. Let’s look at these mechanisms in further detail.

### Retrying failed requests

Many of the failures that occur when accessing external services are transient in nature. For example, there could be network congestion causing a request to timeout, or the service could be under heavy load and is not able to handle any more requests at the time. The best strategy for dealing with such transient failures is to simply retry the failed request – perhaps after a brief backoff period. The `external_service` package uses the [retry library](https://hex.pm/packages/retry) from Safwan Kamarrudin to automate retry logic. This retry library provides flexible configuration to control various aspects of retry logic, such as whether to use linear or exponential backoff, the maximum delay between retries, and the total amount of time to spend retrying before giving up.

### Circuit breakers for preventing catastrophic cascade

The Circuit Breaker pattern was first described in Michael Nygard's landmark book [Release It!](https://pragprog.com/book/mnee/release-it) and was later popularized by Martin Fowler on his [bliki post](https://martinfowler.com/bliki/CircuitBreaker.html). To quote Nygard, “Circuit breakers are a way to automatically degrade functionality when the system is under stress.”

The Circuit Breaker pattern is modeled after electrical circuit breakers, which are designed to protect electrical circuits from damage caused by excess current. Like these electrical circuit breakers, software “circuit breakers” are designed to protect the system at large from damage caused by faults in a component of the system. By protecting calls to external services, the circuit breaker can monitor for failures. If the failures reach some given threshold, the circuit breaker “trips” and further calls to the service will immediately return an error without even making a call to the external API itself. After a configurable period of time, the circuit breaker is automatically reset and calls to the external service will once again be attempted with the same monitoring as before.

In contrast to retry logic, which is applied to each individual call to a service, the circuit breaker for a given service is global to the entire system. If a circuit trips, then it trips for all users of the associated service. This is a key feature of the Circuit Breaker pattern, and is what allows it to prevent cascading failures.

The `external_service` package uses the [Erlang fuse library](https://github.com/jlouis/fuse) from Jesper Louis Andersen for implementing circuit breakers. To extend the electrical analogies, circuit breakers in the fuse library are called “fuses.” These fuses can be used to protect against cascading failure by first asking the fuse if it is OK to proceed using the `:fuse.ask` function. If this function returns `:ok` then it is OK to proceed to calling on the external service. If, on the other hand, it returns `:blown,` then the fuse has been tripped and it is not safe to call the external service. In this scenario, your code must have a fallback option to compensate for the fact that the external service is unavailable, which might mean returning cached data or indicating to the user that the functionality is not currently available.

What causes a fuse to trip?
When using a fuse, your application code must tell the fuse about any failures that occur. If you’ve asked the fuse if it is OK to proceed but then receive an error from the external service, your code should call the `:fuse.melt` function, which “melts the fuse a little bit”. Once the fuse has been “melted” enough times, the fuse is tripped and future calls to `:fuse.ask` for that fuse will return `:blown`.

ExternalService wraps the functionality provided by fuse in a convenient interface and automates the handling of the fuse so that you don’t need to explicitly call `:fuse.ask` or `:fuse.melt` in your code. Instead, you simply use the ExternalService.call function with the name of the fuse as the first argument, together with the function in which you’ve wrapped your call to the external API. Then, the ExternalService.call function will first ask the given fuse before making the call and will return `{:error, :fuse_blown}` if the fuse is blown. It will also automatically call `:fuse.melt` any time the call to the given function results in a retry. This eventually results in a blown fuse if there are enough failed requests to the service being protected by the fuse.

The only requirement for using a fuse for a particular service is that it must be initialized before using the service. This is done with the ExternalService.start/2 function, which takes the fuse name and options as arguments. The fuse name is an atom which must uniquely identify the external service to which the fuse applies. This function should be called in your application startup code, which is typically the `Application.start` function for your application.

### Rate Limiting

Since version 0.8.0, `ExternalService` allows for rate limiting of calls to a service by specifying the rate limit as an optional argument to `ExternalService.start`. If the `rate_limit` option is passed to `ExternalService.start`, then all calls to the external service will be automatically rate-limited. Once the number of calls to the external service has exceeded the limits for a given time window, then `ExternalService` will delay the call to the service until the time window has expired and calls to the service are allowed again. The delay is accomplished using Elixir's `Process.sleep/1` function, so if you are using `ExternalService.call` then the calling process is put to sleep for the specified time window. If, on the other hand, you are using `ExternalService.call_async` or `ExternalService.call_async_stream`, then it is the background process(es) that are put to sleep, and the calling process is _not_ put to sleep in this case. In any case, the rate-limiting is applied to all calls to a particular service across your application so that you can rest assured that you will not violate the rate limits imposed by the external service that you are calling.

Applying rate limits to an external service is as simple as specifying the limits in `ExternalService.start`, as in the following example, which limits calls to `:some_external_service` a maximum of 10 times per second:

```elixir
ExternalService.start(:some_external_service, rate_limit: {10, 1000})
```

## Usage Examples

Below are some example usages of `ExternalService` that illustrate how to configure fuses and retries, and how to use the various forms of the `call` functions for using an external service reliably. The examples are adapted from the Ropig code base that was the original use case for `ExternalService`, and they show how to use `ExternalService` for interacting with Google's `Pub/Sub` messaging service.

### Fuse initialization

```elixir
defmodule PubSub do
  @fuse_name __MODULE__
  @fuse_options [
    # Tolerate 50 failures for ever 1 second time window.
    fuse_strategy: {:standard, 50, 1_000},
    # Reset the fuse 5 seconds after it is blown.
    fuse_refresh: 5_000
  ]

  def start do
    ExternalService.start(@fuse_name, @fuse_options)
  end
```

### `ExternalService.call` and retry options

This example illustrates the usage of the `ExternalService.call` function and some of the retry options that can be used to control retry behavior.

```elixir
defmodule PubSub do
  @retry_errors [
    408, # TIMEOUT
    429, # RESOURCE_EXHAUSTED
    499, # CANCELLED
    500, # INTERNAL
    503, # UNAVAILABLE
    504, # DEADLINE_EXCEEDED
  ]
  @retry_opts %ExternalService.RetryOptions{
    # Use linear backoff. Exponential backoff is also available.
    backoff: {:linear, 100, 1},
    # Stop retrying after 5 seconds.
    expiry: 5_000,
  }

  def publish(message, topic) do
    ExternalService.call(PubSub, @retry_opts, fn ->
      kane_result = Kane.Message.publish(message, %Kane.Topic{name: topic})
      case kane_result do
        {:error, reason, code} when code in @retry_errors ->
          {:retry, reason}
        _ ->
          # If not a retriable error, just return the result.
          kane_result
      end
    end)
  end
end
```

We wrap our call to the external service in a function and pass this function to `ExternalService.call` with retry options as the second argument. Importantly, we use a special return value from our anonymous function to trigger a retry. A retry is triggered by one of three mechanisms:

1. the function returns `:retry`
1. the function returns a tuple of the form `{:retry, reason}`
1. the function raises an Elixir `RuntimeError`

In our example code, we examine the result of calling Kane.Message.publish and if it is an error response with an error code that matches one of our predetermined `@retry_errors`, we then trigger a retry.

Not all failed requests should be retried, of course. Some failures are due to bugs in the calling code; such calls can never succeed and therefore should not be retried. In our case, we consulted the documentation for Google Pub/Sub to determine which error codes should result in a retry. You will have to decide on a strategy to determine what error conditions are retriable for your service.

### Other forms of `ExternalService.call`

In addition to the [`call`](https://hexdocs.pm/external_service/ExternalService.html#call/3) function shown above, the `ExternalService` module also provides other forms of call with slightly different behaviors:

* [`call!`](https://hexdocs.pm/external_service/ExternalService.html#call!/3) - like `call` but raises an exception (instead of returning an error tuple) if retries are exhausted or the fuse is blown
* [`call_async`](https://hexdocs.pm/external_service/ExternalService.html#call_async/3) - asynchronous version of `call` that returns an Elixir `Task` that can be used to retrieve the result
* [`call_async_stream`](https://hexdocs.pm/external_service/ExternalService.html#call_async_stream/5) - parallel, streaming version of `call` that is modeled after Elixir's built-in `Task.async_stream` function


In the code example that follows, some of these various forms of `call` are illustrated using the same `@retry_errors` and `@retry_opts` from the previous example above.

```elixir
defmodule PubSub do
  # same @retry_errors and @retry_opts from above example...

  # Will raise a `RetriesExhaustedError` or `FuseBlownError` in event of failure.
  def publish!(message, topic) do
    ExternalService.call!(PubSub, @retry_opts, fn ->
      kane_result = Kane.Message.publish(message, %Kane.Topic{name: topic})
      case kane_result do
        {:error, reason, code} when code in @retry_errors ->
          {:retry, reason}
        _ ->
          # If not a retriable error, just return the result.
          kane_result
      end
    end)
  end

  # Returns an Elixir `Task`, which can be used to retrieve the result,
  # using `Task.await`, for example.
  def publish_async(message, topic) do
    ExternalService.call_async(PubSub, @retry_opts, fn ->
      kane_result = Kane.Message.publish(message, %Kane.Topic{name: topic})
      case kane_result do
        {:error, reason, code} when code in @retry_errors ->
          {:retry, reason}
        _ ->
          # If not a retriable error, just return the result.
          kane_result
      end
    end)
  end
end
```

## Documentation

See [my blog post](https://ropig.com/blog/use-external-services-safely-reliably-elixir-applications/) for overview documentation, and then check out the [API reference](https://hexdocs.pm/external_service/api-reference.html) for full details.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `external_service` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:external_service, "~> 0.8.0"}]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/external_service](https://hexdocs.pm/external_service).

Sponsored by Ropig http://ropig.com
