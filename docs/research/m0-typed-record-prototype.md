# M0 first typed task-result transport prototype

Tracking: [Issue #11](https://github.com/alex-1974/concurrency-d/issues/11).

Status: internal proof only; **not** the public `Executor.submit` or
`TaskHandle!T` contract.

The existing 8-byte non-owning `TaskRef` and 8-byte `TaskHeader` remain
unchanged. A concrete `ScalarTaskRecord!T` carries a
compile-time-typed function pointer, one scalar argument, scalar result
storage and an atomic completion indicator. Its matching thunk retrieves the
record at the narrow type-erasure boundary, calculates, stores the result
and signals completion with release ordering.

This first slice deliberately admits only `int`, `long`, `ulong` and
`@safe @nogc nothrow` one-argument function pointers. The scalar result is
read only after the pool has joined or the release/acquire completion flag
reports finished. A small ingress capacity verifies that `full` retries
retain the record without duplicating execution.

The caller retains the entire record until `closeAndJoin()`. Neither
`TaskRef` nor the queue takes ownership. The helper establishes pointer
publication using the same shared-header transport already qualified in R0.2.

Next steps for issue #11, not implemented by this prototype:

- general `void` and non-scalar `T` results;
- owned callable/capture storage, including GC visibility and D move rules;
- catch and propagate user exceptions without killing a worker or losing
  completion accounting;
- a typed handle that can wait without shutting down the whole executor;
- clear rejection/cleanup semantics for owned submission;
- `@safe`/scope escape tests for user-facing code;
- actual consumer examples and the public API naming decision.

This avoids promising arbitrary safe cross-thread borrowed closures from a
prototype that cannot yet enforce their lifetime.
