# R0.4 P01 — Portable parking baseline in the M0 submission pool

Status: **candidate, pending CI and targeted stress qualification**.
Tracking: [#10](https://github.com/alex-1974/concurrency-d/issues/10).

## Wait-state model

The M0 `TaskInbox` uses a `core.sync.mutex.Mutex` and a
`core.sync.condition.Condition` associated with that mutex. The
condition variable is the blocking primitive, **not** the source of
truth. The actual predicate consists of:

- `generation`: incremented under the mutex when a task is admitted,
  local work is announced, shutdown is requested, or final closed
  completion is observed;
- `used`: number of accepted but not yet claimed inbox slots;
- `closed`: rejects new tasks;
- `accepted/completed`: tracks in-flight obligations even after claims.

A worker snapshots `generation` *before* its normal local-pop,
inbox-batch and round-robin-steal search. If search fails and shutdown
has not drained the pool, it acquires the mutex and waits only while:

```text
current_generation == observed_generation
and inbox_used == 0
and not (closed and completed == accepted)
```

`Condition.wait` atomically unlocks the associated mutex while
sleeping. A producer changing generation and notifying under the mutex
cannot slip between the predicate check and actual wait. Spurious
wakeups recheck the predicate.

When a worker moves inbox tasks into its private local deque, it
announces that work under the same generation protocol so a sleeping
thief can retry stealing. When the final accepted task completes after
close, notify-all wakes all remaining sleepers for termination.

## Wake policy

- Ordinary accepted submission: increment generation and notify-one.
- New local worker-deque tasks: increment generation and notify-one.
- Close: increment generation and notify-all.
- Final completion after close: increment generation and notify-all.

There is no indefinite yield-spin in the idle worker path. This is a
minimal portable baseline; it makes **no claim** that notify-one or
zero-spin parking is optimal for throughput or wake latency.

## Tests

- Multiple producers and 1/4 workers with bounded ingress.
- Deterministic before-park publication test.
- Repeated idle -> isolated task -> idle transitions.
- Shutdown while workers are parked.
- Submit/close racing; exactly once for accepted tasks.
- DMD 2.111, LDC 1.41 and native ARM64 CI.

## Deferred

Detailed wake-latency percentiles, idle CPU measurements and native
futex comparisons remain the later R0.4 performance gates. Future
scoped/typed task API and general task cancellation remain separate.
No user-facing API is frozen by P01.

Known pragmatic limitation: completion bookkeeping uses the ingress
mutex per finished task. This favors simple correctness in P01;
throughput tuning can replace it only after an equivalent baseline
is measured.
