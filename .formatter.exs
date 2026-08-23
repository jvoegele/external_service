locals_without_parens = [
  call: 1,
  call: 2,
  call!: 1,
  call!: 2,
  call_async: 1,
  call_async: 2
]

[
  inputs: [
    "{mix,.formatter}.exs",
    "lib/**/*.{ex,exs}",
    "test/**/*.{ex,exs}"
  ],
  # line_length: 100,
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
