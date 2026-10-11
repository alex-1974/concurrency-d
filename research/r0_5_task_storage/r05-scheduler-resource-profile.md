# R0.5 producer / process CPU and scheduler study

Status: **diagnostic only**. Tracking [issue #20](https://github.com/alex-1974/concurrency-d/issues/20)
and [research PR #35](https://github.com/alex-1974/concurrency-d/pull/35).

## Why

Five repeated XPS experiments showed that total throughput falls
substantially as producer count increases, **without any capacity
backpressure** for budgets 64+. The exact cause is not proven:
admission lock contention, thread scheduling, GC, producer allocations,
and tiny synthetic workloads can all contribute. Per-admission clock
instrumentation itself reduced throughput, especially at one producer.

This slice deliberately makes **no executor architecture change**.
It adds observation at producer thread boundaries, and a workload
control with verifiable nontrivial computation.

## Measurement mechanisms

D's Linux-only research module
`benchmarks/task_pipeline/thread_resource.d` samples
`getrusage(RUSAGE_THREAD)` at the beginning/end of **each producer
OS thread**, well outside `trySubmit`. The GNU/Linux value for
`RUSAGE_THREAD` is 1. Results are saved into producer-specific
slots and read only after `Thread.join()`.

Per-producer summed deltas:
- user and system CPU time, microseconds;
- voluntary/involuntary context switches;
- minor/major page faults.

The Python runner's `os.wait4` separately provides the whole child
process's user/system CPU time, voluntary/involuntary context switches,
page faults, and peak RSS. This process-wide total includes worker
threads, producer threads, main/control thread, runtime/GC activity.
**Do not subtract producer CPU and label the residual 'exact worker
CPU time'**: snapshots cover different intervals, accounting
granularity and miscellaneous runtime work.

Linux `getrusage(RUSAGE_THREAD)` is documented by
[Linux man-pages](https://man7.org/linux/man-pages/man2/getrusage.2.html).
This facility is not exposed as a public concurrency-d API.

The previous result CSV (`multi,mixed,...`) remains compatible with
the existing R0.5 scripts. Separate `resource,...` and `workload,...`
rows add the new metrics; the scheduler driver requires exactly one of
each. The extra boundary syscalls are not in the inner admission loop,
but they still contribute a small startup/shutdown cost.

## Workload control

The existing `minimal` mode remains the default. The optional
`compute` mode performs 1024 iterations of deterministic unsigned
integer mixing in **every** task, with an input depending on task ID.
Scalar/wide TaskHandle results include and verify a digest-derived
supplement. The void tasks atomically accumulate a separate compute
checksum, verified exactly *after* the timed interval.

Important semantics:
- GC-fresh vs typed-recycle always performs identical work for the
  same workload and task-ID partition.
- Minimal and compute represent **different** task cost models and
  must not be presented as equivalent-work speed comparisons.
- `compute` adds one checksum atomic increment for void tasks, so it
  is not purely compute-only; it is deliberately an observable,
  independently verified payload. Same checksum work for each compared
  storage policy and producer count.
- As with earlier studies, every 17th handle is observed and all
  accepted tasks complete, even if handles are dropped.

## Reproduce on the Dell XPS

Use the **actual** local repository checkout:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only

python3 tools/research/r05_scheduler_resources.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budget=512 \
  --policies gc recycle \
  --workloads minimal compute \
  --counter striped \
  --output=evidence/r05-xps-scheduler
```

The driver builds with optimized LDC and no admission timestamps,
then runs each configuration in a fresh child, alternating **producer
count order** between rounds. Paired scaling ratios compare one,
four, or eight producers only within the same workload and storage
policy. CSV files `raw.csv` and `summary.csv` and
`environment.txt` are generated. CPU governor is queried when
available; it may still change dynamically, so this is not an
enforced frequency/thermal control.

If a larger workload is required for stable CPU accounting, increase
`--tasks` and keep all other dimensions fixed; record CPU/thermal
conditions and system background load. The Linux `getrusage`
quantities measure cumulative CPU time, **not instantaneous
utilization** or individual admission blocking durations.
No kernel perf-event privileges are required.

## Gate and limits

CI checks all three current compiler targets (DMD 2.111 and LDC 1.41
on x86-64, plus native ARM64 LDC) for correctness. A short LDC x86-64
and ARM64 matrix emits non-gating diagnostic artifacts for both
storage policies and both workloads.

A real submission-queue redesign is **DEFERRED** until:
1. Separate process CPU from producer CPU, and compare voluntary /
   involuntary switches with increasing producer counts;
2. Compare the scaling curve of minimal versus compute work within
   identical ownership/result semantics;
3. Inspect full GC activity and controlled XPS scheduling conditions;
4. Preserve producer/result/GC correctness, especially when moving
   allocations or removing synchronization from admission.

Do not infer C++/Rust parity, GC-pause causality, or a proven
lock-free speedup from Linux resource counters alone.
