# Changelog

## [0.2.0] - 2026-10-23

- Add bounded lexical `TaskScope` groups, cooperative cancellation, and
  a typed two-way `Executor.join` to the public API.
- Define cancellation as an idempotent shared request that never replaces the
  callable's single result, including completion and shutdown races.
- Keep owned and scoped callable submission `@system` based on external
  DIP1000 positive, negative, and raw-pointer limitation probes.
- Add same-executor worker helping for scoped admission and joins, recursive
  fork-join validation, and matched scope/fork-join/storage diagnostics.
- Add a public-path owned-storage diagnostic for tiny, large and GC-graph
  callables; retain GC-owned task records and defer stack/pool alternatives as
  recorded in ADR-0005.
- Coalesce external-publication notifications when no worker is enrolled in
  the portable condition wait, preserving generation, local-handoff, close,
  and final-completion wake semantics.
- Keep typed `join` and lexical scopes as the v0.2 composition surface; defer a
  general Sender/Receiver layer until a concrete consumer requires scheduler
  handoff or lazy asynchronous graphs.

## [0.1.0] - 2026-10-22

- Publish the bounded CPU `Executor`, typed `TaskHandle` results, and typed
  executor-use exceptions through `import concurrency` on DUB and GitHub.
- Add bounded admission, explicit draining shutdown, and a documented
  fail-stop boundary when native worker lifetime cannot be proven.
- Include a public-only consumer example, lifecycle/API regression gates,
  package-archive consumer validation, and scoped XPS performance evidence.
