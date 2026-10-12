# R0.5 — Admission critical-section stages: opt-in full-victim qualification

**Status:** research instrumentation and correctness smoke **PASS**; a native Dell XPS
performance result has **not** yet been collected for this new probe.
Tracking: [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20),
grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35).
Prior mechanism: [native lookup study](results/xps-recycle-lookup-review-2026-10-12.md).
**Baseline:** The same full N-slot self-skipping victim search as accepted
into `develop` via PR #37. R0.5 remains a distinct experimental
owned-task implementation, not a throughput stand-in for M0.

## Motivation

On Dell XPS, the three-layout heterogeneous spare-cache scan averaged
~1.4–2.0 RTTI casts/task and whole scan/rearm ~0.1–0.2 µs,
only ~2–3% of **instrumented** producer lock-hold time. Meanwhile
multiple producers incurred ~25–77 µs of **instrumented** mean mutex
acquisition wait per attempt. It is thus more informative to subdivide
the existing admission **critical section** before trying a new
allocator, mutex, index or lock-free queue.

## Instrumentation boundaries

DUB configurations:

| Mode | Configuration | Work done |
|---|---|---|
| `off` | `task-pipeline-mixed-full-victim-sweep` | Normal, uninstrumented `submit`; full victim scan |
| `on` | `task-pipeline-mixed-full-victim-admission-stages` | Compile-time `R05AdmissionStageProbe`, existing per-producer `submitObserved` mutex wait/hold probe; same full victim scan |

Only `on` builds compile stage timer calls and per-producer stage fields.
The existing `AdmissionProbe` is exclusively written by **its producer
thread**, read only after producer joins; stage instrumentation itself
does not add mutexes, atomics, GC allocations or change producer
publication semantics. Timer/counter overhead inside the existing
mutex **does perturb** end-to-end timings and contention. The `off`
binary is a separate control, not an attempt to subtract profiler
overhead.

Four stages, timed with `MonoTime.currTime.ticks` and converted
to nanoseconds by `ticksToNSecs`:

1. **`gate`**: after lifecycle check, from before retention capacity
   pressure/optional `reapCompletedUnderLock` through the advisory
   ingress-capacity check. **Runs once for every attempt**, including
   rejected attempts; these rejected operations do not allocate a
   result cell, handle or node.
2. **`cell`**: `new ResultCell!R` and `new TaskHandle!R`;
   only after capacity permits proceeding.
3. **`node`**: `recycleTyped` search/typed cast/rearm or allocation
   of a new `OwnedNode!(F,R)`; counts include node creation/reuse
   and optional hidden GC/RTTI time, not pure allocation cost.
4. **`publish`**: root append and `_pool.trySubmit` publication;
   the timer stops before unusual failed-publication cleanup.

All counts are per-producer, summed **after joining threads**.
Stage counts in this accepted-work workload satisfy:
`gate_count = attempts = tasks + retention_full + ingress_full`,
`cell_count = node_count = publish_count = accepted = tasks`.
Every task/result/GC-visible/void/worker join condition of
`multi_producer.d` remains enforced, including actual accepted
and completed counters. No performance threshold is imposed by CI.
A rejected attempt is measured in `gate` and never enters a
post-gate allocation section.

The stage time means are `stage_ns/stage_count`; the producer
mutex wait/hold comparison uses **all admission attempts**, not just
successful ones. The stage timers and code between stage boundaries
are **not** an exact decomposition: unmeasured instructions,
clock overhead, and lock-exit housekeeping remain. The diagnostic
`sum(stage_ns)/mutex_hold_ns` is **not an unbiased fraction of
application time or a causal explanation** of the rate loss. Producer
time sums can exceed process wall-clock due to simultaneous threads.

## Reproduce on Dell XPS

Use the *actual* local checkout location and preserve local untracked
research data before switching. It has previously been
`~/Programmiersprachen/dlang/concurrency-d`.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_admission_stage_matrix.py \
  --compiler=ldc2 --workers=4 \
  --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --workload=minimal --counter=shared \
  --output=evidence/r05-xps-admission-stages

tar -czf r05-xps-admission-stages.tar.gz \
  -C evidence r05-xps-admission-stages
```

On AC power without competing heavy workloads, this yields
**120 fresh child processes × 30,000 tasks = 3.6 million tasks**:
five paired rounds, 1/4/8 producers, budgets 8/512, both GC/recycle
and both instrumentation modes. Execution order alternates within
round and between rounds. Because mode changes code and timing, only
compare `recycle/GC` **within the same mode**.

Outputs:
- `raw.csv`: all 120 scenarios, resource counts, producer-GC bytes,
  throughput and (on only) attempt and four stage times/counts;
- `pairs.csv`: same-round `recycle/GC` throughput for each
  instrumentation mode (60 pairs);
- `diagnostics.csv`: 60 per-profiled-case GC/recycle stage means and
  admission lock wait/hold/retry counters;
- `summary.csv`: 12 five-round grouped medians and directional wins;
- `environment.txt`: exact Git HEAD, LDC/DUB versions,
  `lscpu` and governor snapshot, parameters and interpretation limits.

`GC.allocatedInCurrentThread()` is **producer-thread only**,
`wait4.ru_maxrss` is **each fresh child process peak RSS**,
and neither is an exact breakdown of allocation site costs.
The workload defaults to **minimal**; do not join its statistics to
the independent 100k-task full-victim study or M0 compute-1024 data
as though the workloads, timing conditions or implementation match.

## Technical gates and decision

- Three-platform correctness/formatting gate on the exact
  research commit: [GitHub Actions #38250826838](https://github.com/alex-1974/concurrency-d/actions/runs/38250826838),
  **PASS** on DMD 2.111 x86-64, LDC 1.41 x86-64 and
  native LDC 1.41 ARM64. Its 384-task cases are **not**
  native performance evidence.
- Before optimizing, determine whether most hold time in successful
  admissions belongs to `cell`, `node`, `publish` or retention gate,
  and whether observed mutex wait tracks admission retries and worker
  scheduling rather than a single long stage.
- **Do not automatically move cell/handle allocation out of the lock**:
  full-ingress backpressure currently guarantees no allocation on
  rejected submissions. Moving it also changes shutdown/admission
  linearization and could permit discarded allocations.
- **Do not replace the mutex or ownership scheme** on profile data
  alone. Require a separately reviewed variant with equal task
  ownership, typed results, GC roots, move-only/lifetime limitations,
  exactly-once execution and closure semantics, then native paired
  performance with uninstrumented executables.

**KEEP `freshGc`; DEFER structural admission changes and
`recycleTyped` promotion.** Preserve Draft research PR #35,
Issue #20 and the earlier raw evidence. No direct writes to
`develop`, release branches or other workspace repositories.
