# ADR-0004 — Defer a general Sender/Receiver layer

- **Status:** Accepted for the v0.2.0 candidate; release qualification pending
- **Issue:** [#22 — task composition and Sender/Receiver interoperability](https://github.com/alex-1974/concurrency-d/issues/22)
- **Reference inspected:** [Symmetry Investments concurrency](https://github.com/symmetryinvestments/concurrency/tree/5a3613b9ad239579c7460c779540ffa9645e7cfd)

## Decision

**KEEP** `Executor.join`, `TaskScope`, `TaskHandle`, and the cooperative
`CancellationToken` as the v0.2 composition surface. **DEFER** a general lazy
Sender/Receiver layer and executor adapter until a concrete consumer requires
execution-context handoff or callback-style completion. Do not expose a
blanket `TaskHandle`-to-Sender conversion in v0.2.

An adapter may later live in a separate module or package. It must preserve the
executor's bounded admission and post-dispatch lifetime fence rather than hide
them behind an operation state. It must also specify receiver lifetime,
completion thread, cancellation mapping, and what happens when receiver code
throws before it can be considered for the core package.

## Typed composition prototype

`Executor.join(left, right)` is the maintained typed prototype. It schedules
one callable through a one-child scope, evaluates the other inline, drains both
sides, and returns `JoinResult!(L, R)` with fields only for non-void results.
The recursive `examples/nested-scopes` consumer uses it with one and four
workers. Public tests cover typed/void pairs, inline failure after a child has
started, forked-child failure, nested scopes, and single-worker helping.

The matched `benchmarks/fork-join` diagnostic runs `join`, a two-child scope,
and two explicit submissions inside the same driver task. On the recorded XPS
session, all checksums matched; `join` had a 1.192 ms median versus 2.124 ms for
the scope and 2.857 ms for explicit submit/get over 256 pairs. It won all nine
rotated samples. This is evidence for retaining the small primitive, not a
general performance or cross-library claim.

## Evaluation against the issue criteria

| Criterion | Current result | Consequence |
|---|---|---|
| Allocation/runtime | `join` allocates one scheduled child record and runs the other branch inline; the matched diagnostic favors it on the tested XPS workload | Keep the narrow helper; do not add operation-state allocation without a consumer measurement |
| Code size/compiler time | The helper reuses existing scope/handle machinery. A generic sender graph would instantiate connect/operation/receiver types for each composition; no representative consumer exists for a fair compile or binary-size gate | Defer measurement with the feature rather than claim an unmeasured cost |
| Move-only values | Current task nodes and repeatable `get()` require copy-storable callables and results; compile-negative fixtures reject move-only and nonassignable cases | A Sender wrapper cannot repair this storage contract; treat move-only transport as a separate design |
| Errors | Each callable produces one repeatable value or stored exception; scopes drain before propagation | Keep this single-outcome model |
| Cancellation | The token is a shared cooperative request; it neither replaces the callable outcome nor permits early reclamation | Do not invent a Sender `done` channel or map cancellation to an outcome yet |
| Completion | Result readiness precedes the post-dispatch no-worker-access fence; scopes wait for the latter | An adapter must not signal structural completion from readiness alone |
| Executor handoff | CPU work runs on executor workers; controller examples poll/read results and apply them on the controller thread. No scheduler abstraction or UI loop is part of v0.2 | Let Issue #24 provide a real handoff requirement before designing `via`/scheduler concepts |
| API simplicity | `submit`, `withScope`, and `join` make admission, ownership, and joining visible | Retain the small D-native surface |

## Why no minimal core adapter now

The inspected Sender/Receiver reference deliberately has three terminal
channels (`setValue`, `setError`, `setDone`), lazy `connect`/`start` operation
states, stop tokens, scheduler queries, `then`, `whenAll`, `via`, and a nursery.
Those semantics are useful for asynchronous graphs, but they are not a neutral
wrapper around this executor:

- invoking a receiver from the submitted callable fixes completion callbacks
  to a worker unless another scheduler/handoff layer is added;
- blocking `start` on `TaskHandle.get()` is not lazy asynchronous composition
  and can deadlock when used on an exhausted executor;
- converting cancellation into `setDone` would contradict the selected rule
  that cancellation is only a request and the callable's value/error remains
  the sole task outcome;
- dropping the operation state cannot discharge the executor or scope's
  lifetime obligation.

A tiny adapter that ignores these points would demonstrate syntax while
leaving its lifetime and scheduling contract undefined. The existing typed
fork-join prototype is the smaller honest composition result for v0.2.

## Revisit trigger

Reopen this decision when an independent consumer needs at least one of:

1. completion delivery onto a distinct scheduler or UI/event-loop thread;
2. lazy graphs assembled before execution;
3. interoperability with an established D Sender/Receiver component;
4. composition of non-CPU asynchronous operations.

That consumer must provide a minimal end-to-end prototype and measure runtime,
allocation, compile time, and binary size against direct executor use. Until
then Sender/Receiver interoperability is optional research, not a v0.2 gate.
