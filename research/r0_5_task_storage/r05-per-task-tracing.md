# R0.5 — Bounded per-TaskRef event tracing (research only)

Status: **instrumentation / mechanism qualification**, not a scheduler
optimization, new public API, or an accepted causal diagnosis.

## Question

The five-round XPS burst results show delayed runnable siblings with
3/4 workers blocked, often combined with concentrated inbox claims.
Aggregated per-worker counters do not establish which individual TaskRef
entered which owner's deque, whether or when it was stolen, or whether
a particular task was retained by a blocked worker.

This experiment reconstructs **accepted-submission identities** at:
publish → exact inbox claim/batch/worker → enqueue window →
owner-pop or steal (worker/victim) → dispatch begin/end → accounted.
The existing benchmark separately records the actual callable start,
external semaphore-gate release and executor join.

## Isolation

- Only the DUB configuration `burst-head-of-line-trace` defines
  `R05TaskTrace`. The regular library, ordinary burst benchmark and other
  production configurations compile **without** these hooks.
- `TaskRef` and `TaskHeader` remain one word each (8 bytes);
  `containers-d` and its queue algorithms are not modified.
- Trace entries use an increasing **admission ID**, not the raw TaskRef
  address. The private pointer→ID registry is retired after completion
  accounting, **before** the executor marks the record available for reuse.
  Even reusing an identical typed-node address gives a new submission ID.
- The recorder uses bounded arrays (4096 events, 1024 live records).
  If its capacity is insufficient, it records `lostEvents` or
  `registryOverflow`; unknown task references increment `unmatched`.
  Burst validation rejects every incomplete trace.
- The diagnostic mutex protects registry and events. There are no
  new locks, clocks, allocations or trace branches in the standard
  `R05TaskTrace`-disabled scheduling path beyond ordinary compiler code
  generation of the existing operations.
- Snapshots are accessible only after executor `closeAndJoin()`.
  Event output stores logical worker/victim indices and monotonically
  numbered task identities; no raw OS-thread ID or pointer is persisted.

## Crucial interpretation limits

- `MonoTime` is monotonic, and events use the same process timebase,
  but recorder timestamps are **observation times at the trace mutex**.
  They are not an uninstrumented runtime timing oracle.
- `enqueueBegin` happens before `tryPush`, capturing a stable
  submission ID. `enqueueOk` records that captured ID after return;
  it never looks up the potentially recycled pointer again.
  A thief may remove **and finish** the task before `enqueueOk`.
  Therefore stolen, dispatch and even accounted events **may precede**
  `enqueueOk` in serialized trace order. The begin/result window
  brackets successful enqueue rather than defining one atomic timestamp.
- `claimed` is recorded immediately after `takeBatch` returns and
  before the worker can publish/execute that batch. The inbox mutex protects
  the actual claim, but the recorded instant may lag it.
- `dispatchBegin` surrounds the dispatch thunk; it is not exactly the
  start of the user callable. The burst benchmark has a separate atomic
  callable-start timestamp.
- `dispatchEnd` occurs after typed result production and before inbox
  completion accounting; `accounted` is after accounting, but before the
  recycler-release callback.
- The recorder serializes events, adds synchronization and retains a
  bounded registry containing active task pointers. It can perturb
  GC timing, work distribution, steals and wakeups. A mechanism seen
  *only* with tracing cannot be assumed present in the normal executor.

## How to reproduce

```bash
dub test --compiler=dmd --force
dub test --compiler=ldc2 --force

dub run --config=burst-head-of-line-benchmark \
  --compiler=ldc2 --build=release --force -- always gc 4 3 8 100

dub run --config=burst-head-of-line-trace \
  --compiler=ldc2 --build=release --force -- always gc 4 3 8 100

python3 tools/research/r05_task_trace.py \
  --compiler=ldc2 --rounds=5 --probe-ms=100 \
  --blockers 3 4 --policies gc recycle \
  --output=evidence/r05-xps-task-trace
```

The runner compiles two separate builds and alternates the order of the
trace-enabled and trace-disabled child processes across rounds.
It checks identity, batch IDs, enqueue/transfer conservation,
dispatch-on-correct-worker, exact one-time accounting, safe join and
explicit loss counters. Results:

- `cases.csv`: paired child wall time **including** startup and the
  artificial sleep — **not throughput** and **not a scheduler speedup**;
- `events.csv`: address-free per-task event timeline and claim batch;
- `callables.csv`: each accepted submission's actual callable-start worker,
  timestamp and pre-release flag (the burst uses one logical producer);
- `summary.csv`: group medians of child wall-time ratios;
- `environment.txt`: compiler/platform and Git provenance.

The two builds are never considered task-throughput equivalents merely
because their child wall time is similar. Meaningful performance decisions
require a separate uninstrumented A/B with task-start and typed-result
latency distributions, idle CPU, fairness, shutdown and semantic checks.

## Next analysis gate

For each task ID, combine claim worker, enqueue result and owner-pop/steal
victim with the callable worker and external gate-release time. Classify
a delayed sibling as `observed-on-blocked-owner-queue` **only if** its
claim/enqueue worker was already blocked and there is no earlier steal
before the external release. Explicitly mark concurrent/unordered
enqueue/steal windows as uncertain. Compare 3 versus 4 blockers,
notification policies and record storage modes against the paired
untraced burst results.

Do **not** replace the queue, shrink its batch, change notifications,
promote recycling, or merge draft PR #35 on the strength of this
instrumentation alone. Issue #20 remains open.
