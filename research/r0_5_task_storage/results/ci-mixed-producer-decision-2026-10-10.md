# R0.5 mixed multi-producer qualification — first native CI evidence

Date: 2026-10-10. **Research-only.** KEEP `freshGc` as default,
DEFER `recycleTyped` as a generic optimization. These are not
controlled Dell XPS measurements.

## Provenance

- Exact benchmark/source commit: `d9cc2e8f830b94b57c74f8461d070d104293fcd9`.
- [Mixed producer native LDC run #38087396178](https://github.com/alex-1974/concurrency-d/actions/runs/38087396178):
  **PASS** for x86-64 and ARM64, after correcting a missing final CSV
  output specifier discovered by the strict Python harness.
- [DMD/LDC/ARM64 unit and consumer run #38087396173](https://github.com/alex-1974/concurrency-d/actions/runs/38087396173):
  **PASS** on the same source commit.
- LDC 1.41, release builds, GitHub-hosted Ubuntu 24.04; four workers,
  3,000 tasks/case, 2 paired rounds, 1 or 4 producers, budget 8/512.
- Each task index deterministically selects a scalar, GC-visible
  256-byte-payload, or void callable; every 17th TaskHandle is observed,
  all others dropped. Both storage policies perform the same work.

## Paired throughput: typed-recycle / fresh GC

A value above 1.0 favors typed recycling, below 1.0 favors fresh GC.
The table contains the median of **two paired ratios**; this is preliminary
and does not establish statistical confidence.

| Producer | Budget | LDC x86-64 | LDC ARM64 |
|---:|---:|---:|---:|
| 1 | 8 | 1.0089× | 1.0107× |
| 1 | 512 | 1.0049× | 1.0138× |
| 4 | 8 | 0.9182× | 1.0673× |
| 4 | 512 | 1.0674× | 1.0975× |

## Raw rows and memory evidence

- [x86-64: 16 raw pairs' component rows](./ci-mixed-x86-64-2026-10-10.csv)
- [ARM64: 16 raw pairs' component rows](./ci-mixed-arm64-2026-10-10.csv)
- The full workflow artifacts additionally contain per-process `raw.csv`,
  `summary.csv`, `environment.txt` and additional heap metrics.
  Artifacts have finite retention; essential core measurements here are
  permanent in research history.

The `GC.allocatedInCurrentThread()` values are sums of producer-thread
deltas, **not** all allocations across worker threads. `wait4` peak-RSS
measurements had identical coarse per-process values across both policies
in these short trials (x86 ~14,940 KiB; ARM64 ~14,032 KiB). Thus the
short matrix does **not** prove equal peak retention or memory savings.
The additional close/collect used-heap deltas are distinct diagnostic
measures and must not be treated as resident memory.

## Interpretation and follow-up

At four producers with budget 8, recycling improves throughput by roughly
7% on the ARM64 hosted runner but **regresses ~8% on x86-64**. With budget
512, it improves by 6–10% on the two hosted platforms. Two repeats with
3,000 tasks are much too small to choose the default storage policy,
especially with shared atomic-counter contention and host scheduler noise.

Keep the existing GC-owned task semantics. The specialized cache remains
an optional research candidate and must not be merged wholesale into
`develop`. Next: 5+ paired repetitions on the user's XPS under controlled
power/frequency conditions, task counts >=30,000, producer counts
1/4/8, budgets 8/64/512/4096, varied callable type frequency,
GC pause profiles, actual peak RSS and latency distributions. Only then
decide KEEP/REJECT/DEFER for typed recycling.
