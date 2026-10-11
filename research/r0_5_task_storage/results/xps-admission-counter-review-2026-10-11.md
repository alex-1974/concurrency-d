# R0.5 — Native XPS admission and counter-control qualification (2026-10-11)

**Research evidence / decision: KEEP fresh-GC baseline; DEFER recycler and submission redesign.**

## Provenance and verification

Source: user-uploaded Dell-XPS terminal capture `Eingefügter Text(20261011-075926).txt`, **48,041 bytes**, verified SHA-256
`912f7deb5f7f5282dc91f47494930ce8148e0493b70f31c3f16ea2f3fa4c8fee`.

After `git fetch` and `git pull --ff-only`, the checkout fast-forwarded
from `2dd09d8` to **`810894dc32810f2889eee0809eb26f9aeb41637c`**.
The two DUB/LDC release benchmarks ran immediately from that checkout.
The actual local repository is `~/Programmiersprachen/dlang/concurrency-d`.
Prior confirmed XPS hardware: Intel i7-9750H (6 physical cores, 12 logical
CPUs), LDC 1.41.0/LLVM 19.1.7 and Linux 6.17.0-22.
The new log does not contain an independent `git rev-parse HEAD`,
power governor, thermal telemetry, CPU affinity, or new
`environment.txt` values. Do not infer these were controlled.

### Scope

- Four executor workers; **30,000 accepted tasks per process**; five rounds.
- **Admission probe:** 3 producer counts (1, 4, 8) × 4 budgets
  (8/64/512/4096) × 2 counter modes × 2 record policies × 5 rounds
  = **240 complete observations**, i.e. 120 GC/recycle pairs.
- **Uninstrumented counter control:** 3 producer counts × 2 budgets
  (8/512) × 2 record policies × 2 counter modes × 5 rounds
  = **120 complete observations**, i.e. 60 shared/striped pairs.
- Checked the explicit summary ratios/wins against independently
  reconstructed round-paired observations: **all 36 summary values
  and win counts agree to four decimals**.
- Permanent normalized [240-row admission CSV](./xps-admission-2026-10-11-raw.csv)
  and [120-row counter-control CSV](./xps-counter-control-2026-10-11-raw.csv).
- These normalized console rows contain throughput, p95 **histogram
  upper bounds** and retries, but **not** the original per-run
  `raw.csv` values for wait/hold sum, p50/p99, RSS or GC bytes.
  To quantify those fields, preserve the separate local
  `evidence/r05-xps-admission/raw.csv`, `summary.csv`,
  `environment.txt` files. Do not invent missing values.

## 1. Uninstrumented counter-control: striped / shared task counter

Numbers are **medians of the five round-paired ratios**; >1 means
producer-stripe atomics deliver higher total task throughput with
otherwise identical task/result semantics.

| Producers | Retention budget | Fresh GC striped/shared | Typed recycle striped/shared |
|---:|---:|---:|---:|
| 1 | 8 | 0.9798× (2/5 wins) | 0.9067× (0/5 wins) |
| 1 | 512 | 1.0054× (3/5) | 0.9898× (2/5) |
| 4 | 8 | 0.9911× (1/5) | 1.0366× (3/5) |
| **4** | **512** | **0.9572× (0/5)** | **1.0003× (3/5)** |
| 8 | 8 | 1.0114× (3/5) | 1.0139× (3/5) |
| 8 | 512 | 0.9783× (1/5) | 1.0111× (4/5) |

**Important contradiction to the hosted short CI sample:** At four
producers, budget 512, GC-fresh, the *two-round GitHub-hosted*
x86-64 median had favored stripes at 1.2368×. On the actual
Dell XPS over **five paired rounds**, stripes instead lost in
**all five** comparisons (0.9572× median, 0.9351–0.9663× range).
The hosted effect must not be promoted into a general architectural
argument or performance claim.

Splitting the atomic counter does **not** reliably improve throughput
across the 12 local configurations. Its effect depends on storage
policy, producer count and retention budget, with strong variability
especially in the one-producer budget-8 cases.
It may contribute to workload-specific costs, but it is **not a
verified explanation for the observed producer scaling loss**.

## 2. Admission probe: p95 wait versus p95 hold

Every row here uses the opt-in timing path:
`submitObserved`. The reported percentiles are **upper edges of
coarse log2 histogram buckets**, not exact measured p95 latency.

| Producers | Cases | p95 lock-acquisition upper bound | p95 critical-section hold upper bound |
|---:|---:|---:|---:|
| 1 | 80 | 127 ns (all) | 8,191 ns (46), 16,383 ns (34) |
| 4 | 80 | 131,071 ns (all) | 16,383 ns (all) |
| 8 | 80 | 262,143 ns (59), 524,287 ns (21) | 16,383 ns (all) |

Caveats:
- The clock reads and histogram work perturb timings and lock hold;
  maxima/p95 upper-bin values are **not exact latencies**.
- The large separation between wait and hold at 4–8 producers is
  consistent with admission mutex contention **and** thread scheduling
  delays/preemption. It is **not** proof that the mutex algorithm alone
  causes the full slowdown.
- On the 6-core/12-thread XPS, four workers plus eight producers occupy
  up to 12 runnable application threads, before GC or OS activity;
  simultaneous physical-core execution and SMT scheduling matter.

### Backpressure exclusions

- All 180 admission-profile rows with retention budget **64, 512 or 4096**
  have **zero `Thread.yield()` retries**.
- The 60 budget-8 rows have a nonzero or sometimes zero retry count;
  across those rows total retries were 5,630, broken down as:
  1 producer 4,280, 4 producers 634, 8 producers 716.
  These are **aggregate retries across both storage/counter policies
  and five rounds**, not retries per task.
- **No capacity rejection/retry at budget >=64** means
  admission-lock contention and high wait upper buckets at these budgets
  cannot be explained by repeated *rejected* submissions.
  It does not eliminate GC pauses, OS scheduling or contention on
  other synchronization primitives.

### Profiling overhead is material

For the **fresh-GC, shared-counter, budget-512** subset, median throughput:

| Producers | Opt-in admission profiling ON | Same workload OFF | ON/OFF |
|---:|---:|---:|---:|
| 1 | 266,047 tasks/s | 384,004 tasks/s | 0.693× |
| 4 | 188,842 tasks/s | 205,656 tasks/s | 0.918× |
| 8 | 184,017 tasks/s | 190,166 tasks/s | 0.968× |

The diagnostic probe substantially affects throughput, especially in
the one-producer case. Do **not** use profiled absolute throughput as
a production baseline or treat p95 wait as unperturbed lock latency.

## 3. Producer scaling persists with uninstrumented task work

With `freshGc`, shared-counter, budget 512 and **no probe**,
the median total throughput was:

| Producers | Throughput | Versus 1 producer |
|---:|---:|---:|
| 1 | 384,004 tasks/s | baseline |
| 4 | 205,656 tasks/s | −46.4 % |
| 8 | 190,166 tasks/s | −50.5 % |

The denominator is the same **total number of tasks per process**,
not per producer. Increased producer count therefore lowers overall
throughput for this synthetic workload, but causes remain mixed:
serialization, GC/result allocation, producer scheduling, worker
coordination, and synthetic atomic work may all contribute.

## Decision and next qualified experiment

**KEEP** the GC-fresh execution policy already integrated on
`develop`. **DEFER** the generic typed-node recycling policy
on [research Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
and **DEFER** batch, sharded or lock-free admission implementation.
No changes to ownership/result/shutdown semantics are justified
by these measurements alone.

Next research slice should measure, **with minimal timing observer
effect**, CPU time versus wall time and context-switch rates for each
producer/worker, alongside admission wait/hold/retry counts.
Then compare a bounded **single-producer** control, a **multi-producer**
control, and a workload with realistic user computation rather than
solely an atomic increment. Keep all control/target runs paired and
preserve GC allocation and exact result semantics. On the XPS record
power mode, CPU governor/frequency, affinity and temperatures during
each run. Only then propose a concrete admission or cache redesign.
