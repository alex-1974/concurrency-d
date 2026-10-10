# M0 first internal worker batch — integration notes

Status: implementation candidate; **not yet a qualified production execution API**.

Tracking: [issue #8](https://github.com/alex-1974/concurrency-d/issues/8).

## Source basis

- R0.1: production `containers.WorkStealingDeque!(T, Capacity)` remains
  owned by `containers-d 0.2.0`; no second deque implementation.
- [R0.2 P06](https://github.com/alex-1974/concurrency-d/blob/research-integration/research/r0_2_task_representation/results/p06-task-representation-decision.md):
  an 8-byte non-owning `TaskRef`, with type-erased `execute` in a
  minimal record header.
- [R0.3 P06](https://github.com/alex-1974/concurrency-d/blob/research-integration/research/r0_3_worker_scheduling/results/p06-worker-scheduling-decision.md):
  deterministic round-robin victim selection; owner-local pop,
  single/batch stealing, execute-inline overflow.
- Worker threading and task dispatch were adapted from R0.3 P05a flat
  scheduling fixture, not imported wholesale.

## Current vertical slice

`concurrency.internal.worker_batch.runSeededBatch` is an internal,
**synchronous** fixture with a fixed set of already constructed task
records. Each worker seeds and owns exactly one local deque. Other
workers may only steal. Every executing record is claimed through a
deque or from that worker's own overflow path; after executing, the worker
atomically increments the completion count.

The caller must keep the TaskRefs and their target TaskRecords valid until
the function joins all worker threads. The narrow task execute-thunk
currently has `@safe @nogc nothrow` attributes; there is no public
callable/result/exception API yet. This internal runner does not claim to
enforce arbitrary cross-thread borrow safety.

## Not implemented by this slice

- Arbitrary external producer submission and admission: issue #9.
- R0.4 parking/wake (workers currently yield when idle): issue #10.
- Typed user tasks and results: issue #11.
- Startup failure cleanup, errors and lifecycle/shutdown: issue #12.
- Recursive spawning/direct continuation, real irregular graphs and
  end-to-end benchmark parity: issue #8 remains open; issue #14 covers
  final baseline evidence.

The qualified AArch64 saturation-gated direct-one policy only applies
when tasks generate continuations. This flat seeded fixture has none.

## Validation

The `work-stealing-consumer.yml` workflow now triggers for all internal
modules and runs DMD 2.111, LDC 1.41 and native Linux ARM64 builds/tests.
Tests cover one, two and four workers; single and batch stealing; a single
task, small batches and queues larger than the bounded capacity.

No performance claim should be inferred from successful tests. Keep the
existing R0.2/R0.3 native benchmark evidence available for later
end-to-end qualification.
