# R0.5 RUSAGE_THREAD and compute-workload CI qualification (2026-10-11)

**Research diagnostics only.** No public API or production scheduler
architecture change is accepted.

## Qualified implementation

- [Source and reproducible XPS protocol](../r05-scheduler-resource-profile.md)
- [Native LDC 1.41 x86-64 and ARM64 run](https://github.com/alex-1974/concurrency-d/actions/runs/38124197318): **PASS**, both worker
  and producer execution/result invariants passed.
- [DMD 2.111 / LDC 1.41 / native ARM64 consumer gate](https://github.com/alex-1974/concurrency-d/actions/runs/38124197340):
  **PASS** all three jobs, including optimized compute workload checks.
- Source qualified: `d234cd8a82448d7510e22df14cc2d89a91e2b437`;
  later research commits add evidence documentation only.
- [32 raw native hosted observations, compute=1024 rounds](./r05-ci-scheduler-1024-2026-10-11.csv).
  An earlier [32-row exploratory 96-round measurement](./r05-ci-scheduler-2026-10-11.csv)
  is retained to explain why 1024 rounds were selected:
  96 rounds did not sufficiently separate compute from minimal-work
  throughput. **Do not combine these as an identical workload.**

## Measurement design

`getrusage(RUSAGE_THREAD)` is sampled at producer thread entry/exit,
**not** on every task submission. It records producer user/system CPU,
voluntary/involuntary switches, and minor/major page faults.
The isolated Python `wait4()` sampler records process-total
CPU, context switches, faults and peak RSS.

The `compute` workload executes 1024 deterministic integer-mixing
iterations **on each task**; the result is checked in scalar/wide
TaskHandles, and the void-task digest checksum is verified after
shutdown. The `minimal` workload omits the iterations. Each workload
is self-consistent across producer counts and storage policy, but these
two workload families do **not** do equivalent work and must not be
presented as allocator-only speed comparisons.

## Preliminary multi-producer scaling

All values are median of **two paired hosted CI rounds**. Both conditions
have four workers, retention budget 512, 1200 tasks per child process,
and striped task counters. Scaling is total throughput at 4 producers
divided by total throughput at 1 producer **within the same workload**
and storage policy.

| Platform | Workload | GC fresh 4p/1p | Typed recycle 4p/1p |
|---|---|---:|---:|
| LDC x86-64 | minimal | 0.6314× | 0.7073× |
| LDC x86-64 | compute-1024 | **1.2649×** | **1.5496×** |
| LDC ARM64 | minimal | 0.7283× | 0.7216× |
| LDC ARM64 | compute-1024 | **1.0931×** | **1.1380×** |

The high-workload scaling difference is **a hypothesis-generating
result**, not reproducible XPS evidence. It suggests that the previous
negative producer scaling could depend strongly on task granularity,
worker parking/wakeup frequency, and scheduling of tiny tasks.

For example, x86-64 GC/minimal median process voluntary+involuntary
switches rose from **1060.5 (1p)** to **2065.5 (4p)** across the two
hosted runs, while the GC/compute-1024 sample moved from **627.5 (1p)**
to **333.5 (4p)**. This is correlation only:
the compute workload has different work/worker occupancy, small
samples and uncontrolled hosted scheduling. ARM64 does **not** show
the same reduction in compute context-switch count.

## Interpretation and next decision

**KEEP:** current GC-fresh storage and admitted-task lifetime semantics
on `develop`; no new admission algorithm.

**DEFER:** promotion of typed recycle, type-separated free lists, and
lock-free or batched admission. The prior XPS contention diagnosis
remains valid **for minimal tasks**, but cannot be extrapolated to
longer work without the new XPS test.

**NEXT:** execute `r05_scheduler_resources.py` on the local
6-core/12-thread i7-9750H XPS at 30,000 tasks/case and five rounds.
Compare within-workload 1p/4p/8p throughput, per-producer CPU versus
process CPU, voluntary/involuntary context switches, page faults,
GC bytes, and power/governor/thermal state. Preserve raw, summary,
environment. Observing context switches does not identify whether the
cause is lock wait, worker parking, GC or OS preemption.
