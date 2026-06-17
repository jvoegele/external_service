[
  # ElixirRetry's `retry/2` macro expands into code whose success typing makes
  # Dialyzer believe the `{:error, :retry}` and `{:error, {:retry, _reason}}`
  # clauses in the `else` block of `ExternalService.call_with_retry/3` are
  # unreachable. They ARE reached at runtime — see the "retries are exhausted"
  # tests in test/external_service_test.exs — so these are false positives
  # induced by the macro expansion.
  #
  # This filter is scoped to the one function/file affected and should be
  # removed when `call_with_retry/3` is rewritten as part of the 2.0
  # error-handling work (M3/M4). `list_unused_filters: true` will flag it if it
  # ever stops matching.
  {"lib/external_service.ex", :pattern_match}
]
