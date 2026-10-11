# R0.5 worker park/steal instrumentation — native hosted qualification

**Date:** 2026-10-11. **Research evidence only**, not a performance gate
or proof of worker parking as the unique source of producer-scaling loss.

## Source and CI provenance

- Qualifying source commit: `aadc357638337c43b623cb65c4da7ad3c9506a8b`.
  Subsequent commits preserve CI evidence and research documentation only.
- [DMD 2.111 / LDC 1.41 / ARM64 consumer CI](https://github.com/alex-1974/concurrency-d/actions/runs/38128518448):
  **PASS** all three jobs, including opt-in 2048-task accounting, the
  existing generation-based parking/lost-wakeup contracts, deterministic
  real condition-wait/wakeup, GC and type-reuse smoke tests.
- [Native optimized LDC x86-64 and ARM64 matrix](https://github.com/alex-1974/concurrency-d/actions/runs/38128518447):
  **PASS** both jobs. Four workers, 1200 accepted tasks/case,
  2 paired rounds, producer counts 1/4, record budget 512,
  minimal and compute-1024 payloads, GC and typed-recycle policies.
- [64 per-run normalized console observations](./r05-ci-worker-parking-2026-10-11-raw.csv):
  opt-in OFF and ON, measured throughput; ON additionally reports
  actual condition-wait entries and steal attempts/successes.
- [16 paired comparison summaries](./r05-ci-worker-parking-2026-10-11-summary.csv):
  median instrumentation/baseline throughput ratios and rates
  normalized by 1200 executed tasks. The Actions artifact also retains
  the original, more complete `raw.csv`, `summary.csv`,
  `environment.txt` (subject to artifact retention).

## Worker coordination differs strongly by task granularity

**Within a single storage policy** and the same number of accepted tasks:

| Native LDC | Policy | Producers | Workload | Condition waits/task | Failed steals/task |
|---|---|---:|---|---:|---:|
| x86-64 | fresh GC | 4 | minimal | **0.6008** | **1.5433** |
| x86-64 | fresh GC | 4 | compute-1024 | **0.1221** | **0.3358** |
| ARM64 | fresh GC | 4 | minimal | **0.6158** | **1.6533** |
| ARM64 | fresh GC | 4 | compute-1024 | **0.1229** | **0.3504** |

This is a direct, **counted** scheduler observation, not inferred
from process-wide Linux context switches. For 4-producer fresh-GC
minimal tasks, only ~4% of steal attempts succeeded in this particular
2-round hosted sample; compute-1024 tasks saw ~18% x86-64 / ~15%
ARM64 success. Different task granularity makes work more available
to thieves, but the experiment cannot distinguish notification
frequency, worker park timing and OS scheduler behavior.

`Condition.wait` returns include spurious wakeups and shutdown.
An ingress notification does not mean a useful wake. Worker-parking
counts are not themselves the number of OS context switches.

## Observer overhead and noise

The profiler is enabled by an **optional internal boolean**. Workers
only increment thread-local integer fields, recording their snapshot
after exit; inbox counters run under the existing mutex. The
unprofiled path allocates no worker-counters array and does not
read the counters in the task hot path, although the experimental
branch retains conditional checks / changed object layout.

Observed ON/OFF throughput ratios on hosted CI are **variable in both
directions** (e.g. GC 4 producers/minimal x86-64 1.0142×, ARM64
1.0166×; GC 4 producers/compute x86-64 1.0069×, ARM64 1.3738×).
These two noisy rounds do **not** justify calling instrumentation
"free", nor treating timing changes as algorithm improvements.
Use a controlled longer XPS matrix.

## Relation to the existing Dell-XPS evidence

The previously supplied five-round XPS [scheduler result](./xps-scheduler-review-2026-10-11.md)
reported many **mostly voluntary** process-wide context switches,
roughly 79k/30k tasks for GC/minimal at 4 producers and 62k/30k
for GC/compute-1024. Direct worker park/steal counters are the
right next measurement, but the hosted counts above must **not**
be substituted for XPS counts. Furthermore, context switches
from result waits, admission locks, runtime/GC remain possible.

## Decision

- **KEEP** existing GC-fresh owned task execution and producer
  admission/shutdown semantics on `develop`.
- **DEFER** typed-node recycling, lock-free admission and modifying
  condition-variable parking. The new counters identify significant
  idle coordination activity under tiny tasks but do not yet prove
  how much total end-to-end time can be saved safely.
- **NEXT:** run [r05-worker-parking-protocol.md](../r05-worker-parking-protocol.md)
  on the user-controlled six-core/12-thread XPS with 30,000 tasks,
  5 paired ON/OFF rounds and minimal/compute workloads.
  Preserve whole-process CPU/context switches, producer GC bytes,
  wake/steal counts, claim batch sizes and power/governor metadata.
  Compare only matching task/result/ownership semantics.
