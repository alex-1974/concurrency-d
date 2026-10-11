# R0.5 — Native XPS CPU, scheduling and workload granularity (2026-10-11)

**Status: validated source evidence; KEEP fresh-GC default, DEFER recycler/admission architecture.**

## Immutable source provenance

User-supplied archive: `r05-xps-scheduler.tar.gz` with three ordinary
files `raw.csv` (60 rows × 27 fields), `summary.csv` (12 rows),
`environment.txt`. Read from the supplied tarball without shell
execution. SHA-256:

- Full archive `d8ccc2b82815b446866e4db3ceedae74e58863a7690c8003a0f8ec70a909b01b`
- `raw.csv`: `40ab4186fdc76dc98c3f64d045bfe7d075849f523c9f5b3999c92ca950c33fa3`
- `summary.csv`: `1525684dba8d4309458850d44bb76df1db0cc08d14de9520d55e0e4c2ceabd92`
- `environment.txt`: `79e9d337862a17fac7b6035027a5b03473982d0e1a595db538f13d7084ca66f0`

For permanent, inspectable Git evidence, the researcher-normalized
[60-row reduced CSV](./xps-scheduler-2026-10-11-reduced.csv)
preserves **all 60 runs** with throughput, duration, combined
producer/process CPU time, context-switch counts, producer-thread GC bytes,
and node creation/reuse counts.
The exact [12-row summary CSV](./xps-scheduler-2026-10-11-summary.csv)
preserves source-provided group medians. The upload tarball is the
canonical **full 27-field raw source**; the 13-field Git CSV is explicitly
a derived subset and must not be represented as lossless reproduction.

The archive's `environment.txt` establishes:
- `git rev-parse HEAD` = **`c688b7681eb174901ad564c18bc7556b68fb8981`**;
- LDC **1.41.0**, based on DMD 2.111.0 and LLVM **19.1.7**;
- Linux **6.17.0-22-generic**, glibc **2.43**, `x86_64`;
- Intel **Core i7-9750H**, 6 physical cores/12 logical CPUs, 12 MiB L3;
- CPU governor queried on CPU0 = **`powersave`**; this does not
  establish constant frequency, turbo, power supply or thermal stability.
- 4 executor workers, **30,000 accepted tasks/process**, 5 rounds,
  producer counts 1/4/8; retention budget **512**; `striped` atomic
  counters; GC-fresh and type-compatible node-reuse policies;
  minimal vs **compute-1024** workloads.

Every `(round,workload,policy,producer-count)` tuple occurs exactly once.
Every row has 30,000 accepted task nodes (fresh + reused), the expected
1,765 observed handles and nonnegative Linux CPU/context-switch data.
No missing values. Independently recomputed all 12 supplied summary
medians, 1p-relative paired median ratios and CPU/context-switch medians:
**PASS**.

## End-to-end throughput (tasks/second)

Medians from five independent process runs:

| Workload | Policy | 1 producer | 4 producers | 8 producers |
|---|---|---:|---:|---:|
| minimal | fresh GC | 341,341 | 199,561 | 190,190 |
| minimal | typed reuse | 360,094 | 192,409 | 192,484 |
| compute-1024 | fresh GC | 405,185 | 231,146 | 222,951 |
| compute-1024 | typed reuse | 378,113 | 232,753 | 233,826 |

### Producer scaling: median of paired ratios, each versus 1 producer

| Workload | Policy | 4p / 1p | 8p / 1p |
|---|---|---:|---:|
| minimal | fresh GC | **0.5972×** | **0.5595×** |
| minimal | typed reuse | **0.5243×** | **0.5233×** |
| compute-1024 | fresh GC | **0.5828×** | **0.5502×** |
| compute-1024 | typed reuse | **0.6023×** | **0.5548×** |

**Decisive finding:** The short GitHub hosted diagnostics (compute 4p/1p
greater than 1.0 on x86-64 and ARM64 at 1,200 tasks, two rounds)
**did not replicate** on Dell XPS at 30,000 tasks, five rounds.
Compute-1024 throughput is higher in absolute terms for many
configurations, but negative scaling relative to its own one-producer
baseline **persists**. No claim of a producer-throughput reversal is
supported by this larger native dataset.

### Storage-policy comparison (typed recycle / GC) under matched work

Median of **five round-paired ratios**:

| Workload | 1 producer | 4 producers | 8 producers |
|---|---:|---:|---:|
| minimal | 1.1234× (4/5 wins) | 1.0086× (3/5) | 1.0063× (4/5) |
| compute-1024 | 0.8432× (2/5) | 1.0256× (3/5) | 1.0422× (3/5) |

Do **not** compute these from the separate group median rates:
the proper comparison is paired by `round`. At one producer,
the observed variability is extreme: minimal recycler/GC ratio
**0.6521–1.7323×** and compute recycler/GC
**0.6645–1.2112×** across five pairs. Even 5 rounds are insufficient
for claims of a universal storage-policy gain.

## CPU time and context switches

The process-wide Linux `wait4` values include workers, producer
threads, main/control, runtime and GC. The producer-side
`RUSAGE_THREAD` snapshot captures only producer thread execution.
No per-worker CPU attribution is established.

| GC workload | Producers | Median process CPU (ms) | Median producer CPU (ms) | Median process context switches |
|---|---:|---:|---:|---:|
| minimal | 1 | 297.52 | 77.67 | 36,363 |
| minimal | 4 | 524.99 | 217.87 | 79,429 |
| minimal | 8 | 568.90 | 230.06 | 81,806 |
| compute-1024 | 1 | 289.93 | 62.09 | 20,590 |
| compute-1024 | 4 | 544.20 | 198.03 | 62,467 |
| compute-1024 | 8 | 569.72 | 208.17 | 63,698 |

These process context switches are almost entirely **voluntary** in
the observed data, not involuntary preemption. For GC/minimal/4p
the median count is 79,429 switches / 30,000 tasks ≈ **2.65
process voluntary+involuntary context switches per task**.
Compute/4p has 62,467 ≈ **2.08 switches per task**.
This is compatible with a worker-parking/wakeup, blocking/wait or
thread-coordination overhead hypothesis; neither `wait4` nor
`RUSAGE_THREAD` establishes which primitive caused the switches.

The fact that compute-1024 tasks can complete **faster in end-to-end
wall time than minimal tasks** despite additional digest work is
surprising but supported by all five matched fresh-GC rounds per
producer-count. For GC 4 producers, compute/minimal throughput
had paired median **1.1614×**, all 5/5 compute runs faster.
This does **not** mean a loop makes individual CPU tasks intrinsically
faster; it suggests the workload shifts scheduling/coordination
behavior. Investigation of scheduler wakeups, CPU frequencies and
optimized generated code would be required for causality.

## Allocation/retention signals

Fresh GC creates 30,000 concrete task nodes per case.
Typed recycling uses typically ~500–590 fresh typed nodes and
rearms the rest (fresh + reused = 30,000). Nevertheless the producer
GC allocation counter stays around **12.2–12.3 million bytes**
for both policies in most cases because handles and result cells
continue to allocate. The instrument reports producer-thread bytes
only, **not** all process or worker GC allocation and **not** GC
pause duration.

Peak RSS is mostly `18,744 KiB` (one earlier
`18,420 KiB` observation); this coarse plateau cannot establish
equal peak memory retention or GC impact.

## Decision — KEEP/DEFER

- **KEEP** `freshGc` as the production default, with already
  accepted bounded record ownership and nonallocating full-ingress
  rejection on `develop`.
- **DEFER** universal typed recycling: node allocation counts decrease,
  but end-to-end wins are not reliable and producer GC bytes do not fall
  proportionally. No new lifetime safety claim.
- **DEFER** batching, lock-free or sharded admission: native CPU/context
  switches indicate heavy coordination overhead for tiny tasks, but
  cannot identify the mutex, GC and parking shares individually.
- **NEXT** one *narrow* research probe measuring **worker-park and
  wakeup counts, queue occupancy and failed steal cycles**, outside
  expensive per-task timestamping. Include a no-op direct execution
  control if its ownership/result semantics can be defined fairly.
  Compare minimal/compute with the same task/result semantics, worker
  count and power/governor monitoring on this XPS.
- **NEXT** record fixed-frequency or governor/power/temperature
  telemetry across rounds and, if possible, CPU profiler stacks
  (`perf stat`/sampling when permitted). The observed `powersave`
  governor requires caution, not automatic dismissal.

Research [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
remains experimental; [issue #20](https://github.com/alex-1974/concurrency-d/issues/20)
remains open. Do not merge the research branch wholesale into `develop`.
