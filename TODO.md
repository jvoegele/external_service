# TODO

TODO items for external_service

### Todo

- [ ] Address open issues and PRs
  - [ ] https://github.com/jvoegele/external_service/issues/13
  - [ ] https://github.com/jvoegele/external_service/issues/7
  - [ ] https://github.com/jvoegele/external_service/issues/5
  - [ ] https://github.com/jvoegele/external_service/pull/12
- [ ] Reorganize and improve documentation
  - [ ] Break up large README into focused guides
  - [ ] Incorporate ExDoc "cheat sheets" for retry techniques, circuit breaker usage, etc.
  - [ ] Provide guidance for when and how to use ExternalService.Gateway
  - [ ] Remove obsolete sponsorship message
- [ ] Set up sponsorship in GitHub and/or Hex?
- [ ] Improve error reporting
  - [ ] Use structured errors in {:error, tuples}
  - [ ] Ensure exceptions include all relevant details
- [ ] Consider using Flow for call_async_stream
- [ ] Make fuse and retry configuration more readable and discoverable
- [ ] Use decorator annotations for marking functions as external calls that use given retry opts?
- [ ] Improve encapsulation of third-party libraries (fuse, retry, ex_rated)
  - [ ] Consider removing some or all of those dependencies

### In Progress

- [ ] Fix sporadically failing test: test/external_service_test.exs:171

### Done ✓

- [x] Create TODO.md  
