# R0.5 — Intermediate inbox batch sizes and worker idle search

**Status:** opt-in implementation and qualification protocol. No performance
promotion, public task API, new queue or change in default scheduling.

## Evidence motivating the experiments

The five native Dell XPS rounds at original HEAD
`931ede93ffc574c0450508724238ef1d03de0b67` were reviewed in
`results/xps-batch-size-ab-review-2026-10-11.md`.

With four workers and three semaphore-blocked tasks, batch1 started all
160/160 runnable siblings before the gate versus 99/160 for batch8;
its high tail was dramatically lower, but its p50 was slightly worse.
With four blockers, batch1 started 0/160 siblings before gate, while batch8
started 96/160 before the last blocker was running. **Neither** policy
made runnable progress after all four workers were blocked. Minimal-work
throughput differences were noisy; the production-default `gc/always`,
four-producer median ratio favored neither variant.

These observations establish a concrete trade-off, not a universal optimal
batch size or general blocking-progress guarantee.

## Experiment A: sizes 1, 2, 4, 8 (untraced)

One compile-time constant in `submission_pool.d` is selected by exactly
one of `R05IngressBatchOne`, `R05IngressBatchTwo`,
`R05IngressBatchFour`. The ordinary build keeps
`IngressBatchSize = 8`; conflicting opt-in flags fail at compile time.
Each variant uses exactly the same inbox, owner-only
`containers-d` deque, stealing, parking, notifications, GC ownership,
typed results and shutdown contracts.

DUB configurations:
- existing `burst-head-of-line-benchmark` and
  `task-pipeline-mixed-benchmark` (batch8);
- existing `burst-head-of-line-batch1` and
  `task-pipeline-mixed-batch1` (batch1);
- new `burst-head-of-line-batch2`,
  `task-pipeline-mixed-batch2`, `burst-head-of-line-batch4`,
  `task-pipeline-mixed-batch4`.

`tools/research/r05_batch_size_sweep.py` compiles all eight untraced
executables under the same compiler/release flags, uses fresh child
processes and deterministic rotating execution order, and reuses the
previously qualified correctness and timing parser. It checks
exact-once, accepted/completed, typed result values, record retention
and gate/join timing.

- `burst_cases.csv`: actual sibling-start/gate/last-blocker timelines,
  worker-source accounting and per-case sample distribution.
- `burst_siblings.csv`: every runnable sibling with worker ID,
  actual start and pre-gate classification.
- `mixed_cases.csv`: **internally timed** producer-admission,
  execution and shutdown throughput for the same typed/GC-captured
  minimal or compute workload, and whole-child CPU/context-switch
  diagnostics.
- `paired.csv`: each batch1/2/4 versus same-round batch8 contrast.
- `latency_summary.csv`: pooled actual sibling start-offset p50/p95/p99,
  not submission-to-start distributions.
- `throughput_summary.csv`: medians of paired batch/batch8 throughput
  ratios, not the ratio of independent medians.
- `environment.txt`: compiler, architecture, exact Git SHA, workload.

The sample p99 of eight siblings **per case** is just that case's
maximum. Pooled p95/p99 describes the test corpus only.
Each whole-child CPU sample includes runtime startup/teardown and is
not a direct measure of idle worker CPU.

## Experiment B: worker-local steal/park chronology

`worker_search_trace.d` exists solely for
`version (R05WorkerSearchTrace)`. This version allocates **256 events
per worker** before starting threads. Every worker owns one fixed-capacity
event array and monotonically increases **its own** used/lost counters.
No cross-worker mutex or heap allocation is added to the event hot path.
The consumer takes a copy only after `closeAndJoin()`; missing events
fail the benchmark. Normal library builds do not enable this version.

Events:
- `localPop`: successful owner pop;
- `ingressClaim`: claim with actual taken count;
- `stealMiss` and `stealHit`: outcome and victim of one thief attempt;
- `searchEmpty`: no work found in that iteration;
- `parkCheck`: entering `parkUnlessChanged` (does NOT prove sleep);
- `parkReturn`: return, with a detail bit reporting whether
  `conditionWaits` increased (actual `Condition.wait` entered);
- `drained`: exit when completed == accepted after closure.

The trace intentionally **does not** serialize clocks between workers:
event rows are emitted grouped by worker, with per-worker monotonic
timestamps from `MonoTime`. A `stealMiss` says no task was claimed
*in that steal call*, not that its victim's deque was empty during
the entire broader time window. A `parkCheck` is only a park attempt,
not proof of sleep. Conditional waiting may return spuriously.

Separate `burst-head-of-line-search-batch8` and
`burst-head-of-line-search-batch1` build only this lightweight
worker-local trace (without the centralized per-TaskRef trace mutex).
The original burst task/sibling output maps actual blocker starts to
logical worker IDs and gives external gate time. An independent
untraced burst acts as a perturbation control for every recorded case.

`tools/research/r05_worker_search_matrix.py` reconstructs
steal failures/successes, park attempts and waits spanning gate release
for the **unblocked** worker(s) **after the final blocker actually
started**, and only classifies such windows when all blockers started
before the gate. It validates per-worker monotonic order, paired
park-check/return events, counter conservation, complete worker
assignment and zero trace overflow. It writes `cases.csv`,
`workers.csv`, `events.csv`, `summary.csv`, and
`environment.txt`.

## Native Dell XPS reproduction

From a clean `perf/r05-owned-task-pipeline` working tree after updating
from origin:

```bash
python3 tools/research/r05_batch_size_sweep.py \
  --compiler=ldc2 --rounds=5 --burst-ms=100 \
  --blockers 3 4 --policies gc recycle --notify always waiter \
  --tasks=6000 --producers 1 4 --budget=512 --workload=minimal \
  --output=evidence/r05-xps-batch-sweep-minimal

python3 tools/research/r05_batch_size_sweep.py \
  --compiler=ldc2 --rounds=5 --burst-ms=100 \
  --blockers 3 4 --policies gc recycle --notify always waiter \
  --tasks=6000 --producers 1 4 --budget=512 --workload=compute \
  --output=evidence/r05-xps-batch-sweep-compute

python3 tools/research/r05_worker_search_matrix.py \
  --compiler=ldc2 --rounds=5 --burst-ms=100 \
  --blockers 3 4 --policies gc recycle --notify always waiter \
  --output=evidence/r05-xps-worker-search

tar -czf r05-xps-intermediate-batch-and-search.tar.gz \
  -C evidence r05-xps-batch-sweep-minimal \
  r05-xps-batch-sweep-compute r05-xps-worker-search
```

CI uses one small diagnostic round on DMD/LDC x86/ARM64. CI green
qualifies portability/correctness, **not** XPS performance.

## Analysis and decision gate

Compare the paired direction of each intermediate size for **three
versus four blockers**, real gate-relative start and true
post-last-blocker progress, and mixed/compute throughput across producer,
notification and storage factors. Reject configurations whose gains
depend on task reordering that hides runnable tasks behind
simultaneously blocking workers.

For the existing batch8 case with three blockers, determine whether
the remaining worker repeatedly stole from non-owner victims, slept
through queued local work, or saw an empty deque because tasks were
claimed/published later. Distinguish actual waits from skipped park
checks. Compare tracer-on/off pre-gate results to quantify diagnostic
observer effect.

**KEEP:** batch8, `freshGc`, `always`, Draft PR #35 and Issue #20.
**DEFER:** changing default batch size, fairness/notification policy,
queue implementation, `containers-d`, general blocking-progress API
and release promotion until reproducible native evidence supports it.
