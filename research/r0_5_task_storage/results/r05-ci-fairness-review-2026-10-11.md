# R0.5 fairness and semaphore-blocking CI — 2026-10-11

## Verified code

- Implemented on research branch `perf/r05-owned-task-pipeline`.
- Relevant implementation revision: `dd1fb806028b5737bd0b124d3c7e43b5b206abba`.
- [DMD 2.111 / LDC 1.41 x86-64 / LDC ARM64 — PASS](https://github.com/alex-1974/concurrency-d/actions/runs/38134758696).
- [Optimized LDC x86-64 and ARM64 matrix — PASS](https://github.com/alex-1974/concurrency-d/actions/runs/38134758611).
- [All 24 native hosted scenario observations](./r05-ci-fairness-sequential-2026-10-11.csv).
- [Full protocol and Dell-XPS command](../r05-fairness-blocking-protocol.md).

## Distribution: one hosted round, four workers and four producers

All 256 counted typed tasks ran exactly once. All four workers
performed work in every observed configuration. Jain's dispatch
index (no mandatory threshold):

| Native runner | GC always | GC waiter | Recycle always | Recycle waiter |
|---|---:|---:|---:|---:|
| x86-64 | 0.9287 | 0.9403 | 0.9824 | 0.9215 |
| ARM64 | 0.9613 | 0.9580 | 0.9605 | 0.9863 |

One round cannot establish a superior fairness policy, latency
fairness, or starvation-freedom.

## Blocking results

For each platform/storage/notification configuration:

- **One semaphore-blocked worker of four:** all 16 sibling tasks
  finished before the blocked worker was released.
- **All four workers confirmed blocked:** one queued sibling could
  not run before any worker was released, then finished exactly
  once following release.
- Accepted, completed and summed per-worker counts matched.

## Important failed setup and its meaning

The first version published four blockers in a burst. On one
[LDC x86-64 job](https://github.com/alex-1974/concurrency-d/actions/runs/38134605155),
not all blockers reached their semaphores in 10 seconds: a
worker may have taken several tasks as a batch and blocked
before executing the others. This **does not prove task loss**.
The fixed-pool saturation test now admits and confirms each
blocker separately. Burst head-of-line risk remains a
distinct research question, not hidden as a passing property.

**KEEP** the default `always` notification and GC storage;
**DEFER** promoting `waiterAware`, spinning, queue redesign
or new blocking-progress guarantees. No production merge.
