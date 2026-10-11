# R0.5 — Dell-XPS worker-parking and steal qualification (2026-10-11)

**Decision: KEEP GC-fresh production default; DEFER replacing the
condition-variable worker parking and typed recycling.** Research only;
no production scheduler/API changes.

## Provenance and reproducibility

Original user-supplied `r05-xps-worker-parking.tar.gz` contains:

| Artifact | Size | SHA-256 |
|---|---:|---|
| archive | 9,494 bytes | `a81b6fe7db04f5c1905e7abc3979dcd69db2307e68da8ec8bdc0b5dc96046514` |
| `raw.csv` | 18,943 bytes | `464f28d707095c9c72c608dec9e982709cd88b46aac8b4fe1402d0669510642b` |
| `summary.csv` | 1,337 bytes | `c8bf6a079f6b00341926e3d2def8161de8719cd6cc20f205170f8476687cc99f` |
| `environment.txt` | 5,669 bytes | `4afa4121f5a1faf2243e0ad7b504795ee9c1c42f4866768809c671d454aa5a88` |

Original archive is the **authoritative full dataset** (120 rows,
35 fields each, including OS-wide process context-switch and GC
diagnostics). This repository retains:

- [60 paired ON/OFF records with selected per-run metrics](./xps-worker-parking-2026-10-11-paired.csv),
  covering all independent cases and all five rounds;
- [12 group summaries](./xps-worker-parking-2026-10-11-summary.csv),
  copied from the original `summary.csv` and independently checked.
  
These derived Git records are **not** a byte-for-byte copy of the original
35-field `raw.csv`; retain the original tarball and digest to
reconstruct omitted fields.

The archive's `environment.txt` identifies the exact source commit
`9d61926d3b46fabf972d219e6c0baf9bac09833d`, LDC **1.41.0**
(DMD 2.111.0, LLVM 19.1.7), Linux **6.17.0-22-generic** (glibc 2.43),
Dell XPS with Intel **i7-9750H** (6 cores, 12 logical threads),
and observed CPU0 governor **`powersave`**.
No fixed-frequency, thermal, power-source or background-load control
was established. These results are **native XPS data**, not hosted CI.

Configuration: **4 worker threads**, **30,000 accepted tasks/process**,
**5 paired rounds** of worker counters OFF/ON; **1, 4, 8 producer
threads**, **retention budget 512**, **striped execution counters**,
fresh GC vs typed node reuse and minimal vs compute-1024 tasks.

### Validation

- `120 = 5 rounds × 2 workloads × 2 record policies ×
  3 producer counts × 2 profiling modes` distinct tuples;
- all rows report the same workload budget/worker/task contract;
- all rows report `fresh_nodes + reused_nodes = 30,000`;
- ON rows report `executions = claimed_tasks =
  ingress_notifications = 30,000`;
- ON rows report `wait_returns = condition_waits`,
  `steal_successes <= steal_attempts`, `peak_queued <= 64`;
- OFF rows contain empty optional worker/inbox counters;
- all 12 published group medians, five paired ON/OFF rate ratios,
  wait/steal counts and batch-size medians independently recomputed
  from the raw rows: **PASS**.

This validates accounting, not whether workers are optimally parked.

## 1. Actual park and unsuccessful steal pressure

Medians across the five **profile-ON** runs; event counts are
normalized by exactly 30,000 dispatched tasks. Steal success fraction
is the median across five per-run success/attempt fractions.

| Workload | Storage | Producers | Condition waits / task | Failed steals / task | Steal success |
|---|---|---:|---:|---:|---:|
| minimal | fresh GC | 1 | 0.5623 | 1.6928 | ~7.4% |
| minimal | fresh GC | 4 | **0.8601** | **2.5480** | **~3.5%** |
| minimal | fresh GC | 8 | **0.8910** | **2.6116** | **~3.5%** |
| compute-1024 | fresh GC | 1 | 0.3452 | 0.9811 | ~20.6% |
| compute-1024 | fresh GC | 4 | **0.6308** | **1.8906** | ~8.9% |
| compute-1024 | fresh GC | 8 | **0.6555** | **1.9795** | ~8.2% |

With 4 producers, minimal tasks produce roughly **25,803 actual
condition-wait entries** and **76,440 failed steal attempts** per
30,000 tasks (median run); compute-1024 still produces ~18,924 waits
and ~56,718 failed steals. These are **events, not nanoseconds**.
`Condition.wait` can return spuriously or after close, so it cannot
be equated with a useful wakeup, and neither event count can be
equated directly with OS context switches.

For the 4-producer minimal/fresh-GC group, increasing producer
count from 1 to 4 increases waits/task by ~53% and failed
steals/task by ~51%; increasing to 8 is a smaller additional rise.
The direct worker counters therefore support the observed
workload-dependent idle-coordination pressure on this XPS.

Typed-recycle has broadly similar coordination counts and a less
predictable end-to-end rate:

| Workload | Storage | Producers | Condition waits / task | Failed steals / task |
|---|---|---:|---:|---:|
| minimal | recycle | 4 | 0.8313 | 2.4909 |
| minimal | recycle | 8 | 0.8226 | 2.5124 |
| compute-1024 | recycle | 4 | 0.5562 | 1.7106 |
| compute-1024 | recycle | 8 | 0.5895 | 1.8096 |

This does **not** establish that node recycling improves scheduling
efficiency; the storage policies differ internally in memory
management, and the count differences are relatively small.

## 2. Inbox batches underfill despite eight-slot claim capacity

The inbox claims up to **8 tasks in one takeBatch()**. Measured
`claimed_tasks / claimed_batches` group medians:

| Fresh GC | 1 producer | 4 producers | 8 producers |
|---|---:|---:|---:|
| minimal | **2.184** | **1.550** | **1.532** |
| compute-1024 | **2.278** | **1.464** | **1.414** |

With four/eight producers, many worker ingress acquisitions claim
only ~1–2 tasks. The `peak_queued` sample maxima are also far below
the 64-slot ingress limit in many cases; the previous admission
research found zero failed capacity submissions at budget >=64.

Important: the batch limit is 8, but **no policy promises batches
are full**. Workers may drain ingress promptly, producer admission is
serialized, and worker dispatches run concurrently. A larger
per-worker batch size without changes to publication/claim
timing would not necessarily produce larger batches. Artificially
delaying batch take to fill ingress could harm latency, fairness
and result-handle responsiveness.

**Candidate research, not accepted optimization:** compare a bounded
publication/claim or notification-coalescing strategy to the exact
baseline, with identical executed tasks, handle observation,
shutdown/ownership semantics and p50/p95/p99 latency. Do not
increase batch size blindly.

## 3. Does instrumentation materially change throughput?

This is an **isolated paired ON/OFF control** using the same executable
and task semantics but with additional counter writes only for ON.
Numbers are median of five *round-paired* ON/OFF throughput ratios:

| Storage | Workload | 1 producer | 4 producers | 8 producers |
|---|---|---:|---:|---:|
| fresh GC | minimal | 1.0238× | **1.0045×** | 1.0097× |
| fresh GC | compute-1024 | 1.1470× | **0.9557×** | 0.9792× |
| recycle | minimal | 1.0767× | 1.0056× | 1.0427× |
| recycle | compute-1024 | 1.0088× | **0.9366×** | 1.0277× |

The median paired ratio is generally near 1.0 for the more contended
minimal workloads. **This does not mean instrumentation is free:**
some single-producer runs vary wildly, including fresh-GC compute-1024
ON/OFF ratios ranging from **0.6183× to 1.5491×**.
On/off work is semantically matched, but timing remains subject to
CPU power/governor, process startup, GC, OS noise, and the act of
instrumenting under the inbox mutex itself.

At 4 producers, the uninstrumented fresh-GC median throughput is:
- minimal **193,506 tasks/s**;
- compute-1024 **233,422 tasks/s**.

For 8 producers the respective rates are ~193,656 and 222,185
tasks/s. The longer compute tasks can have a higher **total**
throughput while producer scaling remains below the one-producer
baseline. The presence of counted worker churn is compatible with,
but does not prove causality for, that scaling.

## 4. Relationship to Linux context-switch evidence

Profiled fresh-GC minimal/4-producer processes have median
**~79,697 voluntary OS context switches**, versus **~25,803
worker condition-wait entries**. Compute-1024/4-producer processes
have **~62,667 voluntary switches**, versus **~18,924 waits**.

Linux process-wide context-switch counters aggregate producer,
worker, main and runtime threads. Not every context switch comes
from the worker condition variable, and one condition wait can
generate more than one scheduler event. Other plausible blocking
points include task result-cell waits, admission mutex, completion
notifications and GC/runtime coordination. The numerical
difference **does not identify the residual by mechanism**.

The very low steal success on minimal/4p (~3.5%) is another direct
symptom of repeated empty-queue searches. Profiling does not yet
measure `worker entered idle -> notification -> useful task` as a
single attributed cycle.

## Decision and next isolated experiment

**KEEP** production `freshGc` default and the existing
generation-based condition variable park algorithm.
**DEFER** generic typed-recycle promotion, lock-free/batched admission
and spin-before-park.

The best next controlled investigation is **one narrowly scoped
worker-idle prototype**, *not* a wholesale queue redesign:

1. Count successful useful wakeups separately from returns due to
   close, spurious wakeups, generation changes and other workers
   consuming the work; distinguish inbox versus steal task sources.
2. Preserve low-overhead observation and record both ON and OFF.
3. Compare a bounded spin/yield-before-park candidate **only if**
   it retains generation-based lost-wakeup protection, CPU idleness,
   shutdown determinism and GC/ownership/result semantics;
   include idle CPU, low-load latency and fairness gates, not just
   throughput.
4. Consider producer-to-worker wake coalescing or batch
   admission only as a separate, semantically fair hypothesis
   with explicit tail-latency and fairness measurement.

Do not attribute the entire 40–50% producer throughput scaling loss
to parking: high idle coordination and low batch occupancy are
**identified correlates, not yet a causal decomposition**.

Current [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
remains experimental. [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20)
remains open; `develop` must not receive unqualified research.
