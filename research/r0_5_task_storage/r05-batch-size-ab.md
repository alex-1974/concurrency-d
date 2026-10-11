# R0.5 — Isolated ingress batch-size A/B (1 versus 8)

**Status:** research-only measurement design. No production promotion.

## Why this comparison

The user-supplied native XPS per-TaskRef trace at
`bf88e54346fe7705acc2e38e43d93af83e4f33c1` contains 40 cases, 460
accepted tasks and 3413 trace events. Among 320 runnable siblings, 144
started after the external semaphore release. All 144 had been enqueued
by a worker that next executed its claimed batch-head blocker. They were
eventually popped by the owner (131) or stolen (13), mostly after the gate.

This is task-level evidence of head-of-line exposure in that **traced**
burst scenario, not a proof that a batch-of-one policy will improve general
scheduler fairness, throughput or real workload latency.

## Intervention

`source/concurrency/internal/submission_pool.d` has the sole experimental
compile-time switch:

- **batch8**: unchanged normal `IngressBatchSize = 8` in all regular builds;
- **batch1**: `version (R05IngressBatchOne)`, `IngressBatchSize = 1`.

The existing worker algorithm, FIFO inbox, owner-only deque, stealing,
parking, notifications, task record, GC-rooting, typed results, close/join,
and lifecycle remain unchanged. No `R05TaskTrace` flag, trace mutex, or
per-task event recorder appears in either A/B binary. No DUB library
default, public task API or dependency is changed. The separate
`burst-head-of-line-batch1` and `task-pipeline-mixed-batch1` configurations
build the **same** benchmark sources as the existing baseline binaries.

**Hypothesis:** with only three of four workers blocked, a remaining
worker can claim runnable siblings individually rather than finding them
behind a blocked worker's locally claimed batch. For four blocked workers,
**no policy here promises progress** while all workers are blocked.

## Qualified questions and fairness

The two builds submit identical task types/counts, in the same producer
order, with identical ingress, retention and work-stealing queue capacities,
storage and notification settings. They must verify accepted == completed,
once-only callable execution, correct `TaskHandle.get()` values and clean
join. All configurations are rebuilt with exactly the selected compiler
and release flags.

The benchmark now exports the **actual** external gate-release timestamp
on both variants (a 100 ms sleep request is not its exact time).

The paired runner records separately:

1. `burst_cases.csv` and `burst_siblings.csv`: **untraced** callable
   start offsets, actual gate release, last blocker start, pre-gate sibling
   progress, worker identities, worker-source accounting and descriptive
   nearest-rank p50/p95/p99 per eight siblings. Snapshot-before-release
   flags are recorded but not conflated with timestamp-before-gate:
   a callable may start between the snapshot and release.
2. `mixed_cases.csv`: each binary's **internal** end-to-end
   mixed-producer elapsed time and task throughput, including producer
   admission, backpressure, typed work, producer join and worker shutdown;
   minimal or compute workload, GC-visible captures, and sampled outputs
   are the same in both variants. This is **not** the burst child walltime.
3. `pairs.csv`: individual 1-versus-8 paired differences and run order.
4. `summary.csv`: medians of matched case comparisons, separated by
   blocker count, record policy, notification policy and producer count.
5. `latency_summary.csv`: pooled **untraced sibling start offsets** p50,
   p95 and p99 for each configuration, plus post-gate counts, per-case
   medians and child-process CPU diagnostics.
6. `environment.txt`: exact Git SHA, compiler version, CPU/platform,
   round count and workload settings.

The runner alternates order within a case, uses distinct fresh child
processes, excludes builds from timing, and has a 30-second watchdog.
A failed typed-result or admission count aborts the data collection.
Whole-child CPU time and context switches are recorded **only as
diagnostics**; they include startup/GC/shutdown and are NOT a direct
worker idle-CPU measure.

The burst's per-case p99 over **eight** siblings equals the maximum
observed in that case; do not claim statistically stable p99 from this.
Aggregate latency distributions and per-round paired directions are
necessary, along with repeated native measurements, before promotion.
With four fully blocked workers, zero runnable progress before the
external release is an expected limitation, not a failed gate.

## Local reproduction (native XPS)

```bash
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_batch_size_ab.py \
  --compiler=ldc2 --rounds=5 --burst-ms=100 \
  --blockers 3 4 --policies gc recycle --notify always waiter \
  --tasks=6000 --producers 1 4 --budget=512 --workload=minimal \
  --output=evidence/r05-xps-batch-size-ab

tar -czf r05-xps-batch-size-ab.tar.gz \
  -C evidence r05-xps-batch-size-ab
```

The researcher should preserve earlier XPS trace and burst data unchanged.
The hosted CI runs a smaller **correctness/portability smoke**, not
repeatable XPS performance qualification.

## Decision gate

**KEEP**: batch8, `OwnedRecordPolicy.freshGc` and
`NotificationPolicy.always` as defaults. PR #35 remains draft and
Issue #20 remains open.

**EVALUATE**: across repeated native XPS rounds, does batch1
actually change per-task runnable progress and p50/p95/p99 startup
distribution with 3 blockers? Does it hurt mixed workload throughput,
CPU/resource use or fairness at 1 and 4 producers? Are effects consistent
under storage/notification controls, not artifacts of ordering/frequency?

**DEFER**: production batch-size selection, queue replacement, public
scheduler API, proactive waking/spinning, and help-while-wait.

**Related open question:** Why did the remaining free fourth worker fail
to steal some queued siblings before gate release? This A/B does not
resolve that; a bounded optional trace of unsuccessful steal attempts
and parking remains a separate mechanism experiment.
