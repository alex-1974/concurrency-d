# R0.5 — Worker parking, wake and failed-steal qualification

**Status:** experimental counters, **not** a scheduling-policy or public-API
change. Research branch `perf/r05-owned-task-pipeline`; issue #20.
Default `OwnedTaskExecutor` behavior and `develop` remain unchanged.

## Motivation

The user-supplied five-round Dell XPS experiment,
[xps-scheduler-review-2026-10-11.md](results/xps-scheduler-review-2026-10-11.md),
showed 30,000 task workloads scaling negatively from one to four/eight
producers, even when each task performs 1,024 digest iterations.
Voluntary process context switches were common:

- Fresh GC/minimal, four producers: **79,429** median switches / 30k tasks;
- Fresh GC/compute-1024, four producers: **62,467** median switches / 30k tasks.

These observations **do not establish** that context switches came
from worker parking: result-cell waits, admission contention, runtime/
GC and OS thread scheduling also block. This research counts the
worker scheduler's own decisions directly and independently.

## Opt-in instrumentation

`SubmissionWorkerPool` accepts a package-internal
`parkingProfile=false` constructor argument.
`OwnedTaskExecutor` forwards the same optional flag, after its existing
worker, ingress, retention and record-policy arguments.

Counters are disabled by default. Each worker collects plain integer
counters **in its own local stack instance**. A worker publishes one
snapshot to its assigned array slot on loop exit. Callers may only
read aggregated worker stats after `closeAndJoin()` has completed.
This avoids per-event atomics and data races between monitoring and
active workers. No timestamps are taken in this study.

Worker counts:

- `localMisses`: local deque pop found nothing;
- `ingressMisses`: an external inbox batch returned zero;
- `stealAttempts` / `stealSuccesses`: attempts/successes reading
  another worker's deque, allowing exact failed-steal counts;
- `parkChecks`: entered the generation-aware park protocol;
- `conditionWaits`: entered an actual `Condition.wait()`;
- `waitReturns`: returned from `Condition.wait()`, **including
  spurious returns, close wakeups and notifications that did not
  deliver executable work**;
- `skippedParks`: reached the park method but did not wait because
  generation/work/shutdown state had changed;
- `executions`: dispatched tasks, verified equal to accepted tasks
  once the joined executor reports completion.

Inbox counters are updated only while its **existing mutex** is held:

- notifications after each accepted external publication;
- local deque work announcements, close broadcasts and final-drain
  broadcasts;
- claimed ingress batch count and number of tasks in those batches;
- peak queued ingress slots (bounded by ingress capacity).

**Important causal limitation:** `notify` does not guarantee a parked
worker woke, and a `waitReturns` event does not prove it received work.
The counts expose scheduler churn, but not individual notification-to-
worker attribution. They must not be described as latency percentiles
or a proof of where each voluntary context switch originated.

## Invariant and test checks

The normal uninstrumented worker loop and all submission/error/shutdown
semantics are preserved. With the option enabled, tests require:

- exactly one recorded worker dispatch per accepted task;
- worker steal successes <= attempts;
- every entered condition wait returned after join;
- number of ingress accepted notifications == accepted tasks;
- batch-claimed task total == accepted tasks;
- peak queued slots do not exceed ingress capacity;
- zero new counter values when the profile is disabled.

Existing generation-based lost-wakeup regression tests remain active,
including inbox publication between observed generation and park.

### Overhead separation

The R0.5 `r05_worker_parking_matrix.py` runner compares **ON vs OFF
in separate subprocesses**, with identical callable types, task IDs,
result-handle observations, worker count, producer count, GC/recycle
policy, record budget and task granularity. It alternates ON/OFF order
between rounds, and records throughput, process CPU/context switches
and RSS alongside event totals.

The counters do add conditional branches and local integer writes.
Their overhead is measured rather than assumed negligible. Avoid
ranking runs at different instrumentation settings as if task
semantics or scheduler observation costs were identical.

## Reproduce on the Dell XPS

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only

python3 tools/research/r05_worker_parking_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budget=512 \
  --policies gc recycle --workloads minimal compute \
  --counter striped \
  --output=evidence/r05-xps-worker-parking
```

The command writes `raw.csv`, `summary.csv`, `environment.txt`
(including exact source git SHA, compiler version, CPU topology and
governor where exposed), with one child process per case. Retain all
three for review rather than relying only on console summaries.
Power/governor/thermal stability and code generation still require
independent consideration.

A shorter smoke is run in CI using DMD 2.111, LDC 1.41 x86-64 and
native ARM64 LDC; LDC x86-64/ARM64 also runs a non-gating paired
1200-task matrix. Do not equate short hosted timings with five-round
native XPS results.

## Decision gate

The existing default **GC-fresh** remains KEEP.
Typed-node recycling, lock-free admission, batch submission, and
changed worker park strategy remain DEFER.

If workers exhibit frequent `conditionWaits` or failed steals
relative to the number of dispatched tasks, quantify how often the
worker returns and finds work. Then consider **one scoped hypothesis**
(e.g., bounded spin-before-park versus the existing condition-variable
protocol) and compare at unchanged ownership, dispatch completion,
fairness, shutdown linearizability, and package-safety rules.
A higher notification count is *not* evidence by itself to change
the condition-variable algorithm.
