# R0.5 — Worker fairness and blocked-task progress qualification

**Status:** Research-only behavioral characterization of the existing
fixed-size work-stealing executor. Does not propose a scheduler-policy
change, public API, faster algorithm, or production merge.

## Why this probe exists

The native Dell-XPS R0.5 research isolated high worker coordination:
failed steal attempts, real `Condition.wait` entries, and ~44% empty
first searches after a wait for very short tasks. A narrower
waiter-aware `notify` variant had **no repeatable XPS throughput
win**. Before considering notification, queue, spinning or admission
changes, we need to establish work progress and distribution while
one or more workers are blocked.

The scheduler does **not** implement general `help-while-wait`.
`TaskHandle.get()` waits for result completion; it does not execute
dependent tasks on the calling worker. In a fixed pool, blocking all
workers can starve queued work until at least one worker becomes free.
This is a **documented research limitation**, not a deadlock to
reinterpret as a successful optimization.

## Research instrumentation

`SubmissionWorkerPool.workerStatsAfterJoin()` and the equivalent
`OwnedTaskExecutor` package-internal method return a **snapshot
of per-worker counters after `closeAndJoin()`**. Counters belong to
their worker until it exits. No counters are read live and no
per-task timestamp or extra atomic operation is introduced by the
snapshot method. The existing optional parking profiling must be ON
for the distribution to be nonzero; all default behavior remains
unchanged.

The benchmark `fairness-blocking-benchmark` has two scenarios:

### 1. Multithread producer / worker distribution

Four independent producer threads submit distinct callable records.
Every 17th typed result is observed with `TaskHandle.get()`; every
accepted task has its unique `shared uint` execution counter, checked
to equal **exactly 1** after executor shutdown. Aggregate accepted,
completed and all worker-local `executions` counts must match the
total task count. The command reports `worker,<index>,<executions>`
and `fairness,<workers>,<producers>,<tasks>,<active>,<max>,<elapsedNs>`.
This reports empirical distribution only, not scheduling fairness in
the strong sense.

A companion Python runner records active workers, maximum worker
share, and **Jain's fairness index**:

```text
J = (sum(worker_executions))^2
    / (worker_count * sum(worker_executions^2))
```

`1.0` means equal distribution and `1/workers` that a single
worker executed everything. There is **no numerical acceptance
threshold**: instantaneous balance is not promised for small tasks,
and Jain's index does not establish deadline fairness or
starvation-freedom for individual tasks.

### 2. Semaphore blocking and scheduler progress

All blockers enter `Semaphore.wait()` before runnable sibling
tasks are submitted. The gate is controlled by the benchmark
thread, not another executor worker.

- **One blocked / four total workers:** 32 independent sibling
  tasks must finish **before** releasing the blocker, within a
  bounded 5-second monotonic observation window.
- **All four workers blocked:** one queued sibling must remain
  pending during a short 100-ms observation window, **then**
  complete after the controlling thread releases all blockers.
  This is an *expected capacity-exhaustion case*, not a
  guarantee that an arbitrary nested `TaskHandle.get()` can
  safely run on the same saturated pool.
- Every accepted sibling and blocker must still execute exactly
  once; no handle completion, shutdown, retained record or
  `Condition.wait` generation invariant is deliberately weakened.
- The blocking gate is released on an initial-start timeout before
  the executor is joined, avoiding an intentionally abandoned
  sleeping worker in the test.

No arbitrary task runtime deadline, starvation-freedom property,
OS fairness, absolute latency p99, or scheduler-wide
help-while-wait is asserted by this narrow suite.

## Reproduction

The source lives on grandfathered branch
`perf/r05-owned-task-pipeline`, Draft PR #35.
No changes are made to `develop`.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only

# Correctness smoke, repeated in DMD/LDC/native ARM64 CI:
dub run --config=fairness-blocking-benchmark \
  --build=release --compiler=ldc2 --force -- fair always gc 4 4 256
dub run --config=fairness-blocking-benchmark \
  --build=release --compiler=ldc2 --force -- block always gc 4 1 32
dub run --config=fairness-blocking-benchmark \
  --build=release --compiler=ldc2 --force -- block always gc 4 4 1

# XPS repeatability / distribution without fixed speed gates:
python3 tools/research/r05_fairness_blocking_matrix.py \
  --compiler=ldc2 --workers=4 --producers=4 --tasks=1024 \
  --siblings=32 --rounds=5 --policies gc recycle \
  --output=evidence/r05-xps-fairness-blocking
```

The Python tool produces process-isolated `raw.csv`,
`summary.csv`, `environment.txt`. Each observation includes the
notification variant (`always` or `waiter`), storage policy,
worker distribution, CPU time, context switches, RSS and blocking
progress classification. Rounds alternate notification variant
order. No unobserved variable should be inferred constant across
separate hosted runners.

## Research gate

KEEP: `freshGc` and the unconditional-notify generation-based
parking baseline, established shutdown/exactly-once task contract.

DEFER: typed recycling, notify-coalescing, spin/yield-before-park,
batch admission and lock-free inbox. Before attempting a materially
different scheduler, qualify nested/dependency task patterns,
fairness under heterogeneous CPU work and longer sustained
load, latency and idle CPU. Avoid a blocking `get()` inside all
occupied executor workers unless a separate helping mechanism
is designed, qualified and explicitly contracted.

See [XPS notification negative result](results/xps-notification-ab-review-2026-10-11.md).
