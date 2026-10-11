# R0.5: admission-mutex contention versus task counter contention

**Status: research only.** This expands R0.5 investigation [issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
No public Executor API, new allocator, or production task-store policy is accepted here.

## Motivation

The five-round Dell-XPS mixed workload (see
[xps-mixed-2026-10-10-review.md](results/xps-mixed-2026-10-10-review.md))
showed a sharp fall in *total* task throughput when increasing producers
from one to four/eight. It did **not** identify the cause. The benchmark
used both a single `OwnedTaskExecutor` producer-side mutex and one atomic
execution counter across every worker. CPU topology is Intel i7-9750H
(6 cores / 12 logical threads), with four executor workers and
up to eight producer threads.

The following probes answer two separate questions without changing
the accepted task/output/shutdown contract.

## Control A: opt-in admission timing

`OwnedTaskExecutor.submitObserved(F, ref AdmissionProbe)` has the
**same admission, full-queue retry, result, and shutdown semantics** as
`submit`, but calls a compile-time specialized `trySubmitImpl!(F, true)`.
The normal `submit` path specializes the same core to
`trySubmitImpl!(F, false)`, removing the probes at compile time.

Each producer has a separate mutable `AdmissionProbe` instance, used
only by that thread and read after `Thread.join()`:
- number of attempts and successes;
- blocked retention budget / ingress queue attempts;
- number of producer `Thread.yield()` retries;
- nanoseconds of lock **acquisition wait** per `trySubmit` attempt;
- nanoseconds of **critical-section duration**, including allocation,
  optional typed-cache scan, root compaction, inbox publication and
  instrumentation overhead;
- nanoseconds of maxima, and approximate p50/p95/p99 **upper bounds**
  from fixed-sized log2 nanosecond histograms.

Timing uses `MonoTime.currTime.ticks` / `ticksToNSecs`. Each
histogram bin `i` (i>0) contains nanoseconds
`[2^(i-1), 2^i-1]`. The reported percentile is the **upper bound
of its containing bucket**, not an exact percentile.
The calibration overhead of clock reads, histogram updates and
compiler/runtime choices is **included**, so never compare the raw
throughput of a timed probe with the uninstrumented baseline as though
it were an optimization benchmark. Compare like-for-like profiled
GC versus profiled recycle only.

The `scope(exit)` measure executes while holding the mutex, before
`synchronized(_mutex)` exits. The admission mutex itself is unchanged.
The recorded wait excludes work prior to entering `trySubmitImpl`.
Backpressure may also spend time executing `Thread.yield()` outside the
admission lock: **retry counts are measured, not yield duration**.
The sum of observed wait+hold times across threads can exceed elapsed
wall time due to parallel waiting and scheduling; these are not
direct fractions of total elapsed process time.

## Control B: atomic-counter false sharing / hot cache line

The mixed benchmark accepts an optional `shared` or `striped`
counter mode. Both modes execute one release-order atomic increment
for **every** task, preserving comparable task cost and observable
exact completion. The `shared` mode sends all increments to one
`shared(ulong)` address. The `striped` mode has one logical
`shared(ulong)` counter per producer, with successive counters
separated by **16 ulong = 128 bytes** in an array.

Both modes *sum and verify the same total of 30,000* executions.
The striped mode does not eliminate atomic instructions and does not
guarantee there is no interference among worker threads processing
tasks from the same producer. Its only controlled change is
the amount of cross-stream contention for the same cache line.
This is a benchmark-design control, **not** an executor policy change.

## Reproduce locally on Dell XPS

From the **existing local repo** (not an assumed workspace/libs path):

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only
python3 tools/research/r05_admission_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 64 512 4096 \
  --counter-modes shared striped \
  --output=evidence/r05-xps-admission
```

The script compiles the opt-in mixed benchmark, then runs every
`(producer count, budget, counter mode, GC/recycle policy, round)`
in a **fresh Linux child process**, alternating GC/recycle order
between rounds. It emits `raw.csv`, `summary.csv` and
`environment.txt` with git SHA, LDC version and `lscpu`.
The performance numbers include admission-instrumentation overhead.

To compare **uninstrumented** shared versus striped atomic work
separately, run the same executable with `off`:

```bash
dub run --config=task-pipeline-mixed-benchmark --build=release \
  --compiler=ldc2 --force -- 4 8 30000 512 gc shared off
dub run --config=task-pipeline-mixed-benchmark --build=release \
  --compiler=ldc2 --force -- 4 8 30000 512 gc striped off
```

For a **paired uninstrumented** shared-versus-striped benchmark,
use a separate driver instead of comparing independent single-run times:

```bash
python3 tools/research/r05_counter_control.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --policies gc recycle \
  --output=evidence/r05-xps-counter-control
```

This pairs counter layouts within the *same storage policy*, switches
run order between rounds and writes per-child `raw.csv`, `summary.csv`
and source/compiler/CPU metadata. The `off` benchmark path does **not**
call `submitObserved`; it still incurs the one-time mode branch per
submission in the research-only benchmark wrapper. These results
therefore test the shared hot atomic effect, not a frictionless
production API.

The CI research workflow performs a smaller sample on x86-64 and
native ARM64 using optimized LDC, and the consumer gate instantiates
the observed path on DMD 2.111/LDC 1.41 on x86-64 and ARM64.
Hosted CI checks correctness and prints diagnostics, **not** hard
performance thresholds.

## Decision gates

Only after comparing measured wait percentiles, hold percentiles,
retry rates, counter layouts, process RSS and profiler overhead:
- If **lock hold** dominates and grows with producer count, consider
  moving allocation outside the critical section or a batch-admission
  prototype (preserving rejection-no-GC-allocation and shutdown
  linearizability; do not simply revert accepted correctness rules).
- If **acquisition wait** dominates but hold time stays short, evaluate
  producer-channel sharding or another admission queue design.
- If **shared-to-striped** changes throughput substantially, isolate
  benchmark-induced atomic contention before modifying the executor.
- If **backpressure retries** dominate, investigate capacity and
  wait/notify strategy separately from record storage.

No one result alone justifies making typed node reuse the default.
