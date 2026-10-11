# R0.5 — Burst head-of-line scheduling, native CI qualification

**Date:** 2026-10-11. **Decision:** KEEP existing production
`freshGc` and `always` notification. This is strictly
a **research diagnostic**, not proof of scheduling fairness,
starvation, better throughput or a reason to merge Draft PR #35.

## Exact qualified implementation and CI

- [Research protocol and XPS reproduction](../r05-burst-head-of-line-protocol.md).
- [32 complete hosted per-scenario log summaries](./r05-ci-burst-head-of-line-2026-10-11.csv).
- [DMD 2.111 / LDC 1.41 x86-64 / native ARM64 consumer — all PASS](https://github.com/alex-1974/concurrency-d/actions/runs/38136701862).
- [LDC 1.41 x86-64 / native ARM64 research matrix — both PASS](https://github.com/alex-1974/concurrency-d/actions/runs/38136701880).

Executable runner and protocol were qualified on source revision
`d71f837cbd0e74382df11d00232050927533b1a0`.
Follow-up commits store only reports and evidence; no scheduler
or worker code has been promoted. No change to `develop`.

CI configuration: four worker threads, a simultaneous burst
of either **three** or **four** semaphore-blocked typed tasks,
followed by **eight runnable sibling tasks**, then a **60 ms**
`Thread.sleep` observation window with gate closed, and
external release of all blocker semaphores. Two process-isolated
rounds each for `gc`/`recycle` and `always`/`waiter`,
on each of native x86-64 and ARM64. All accepted work is checked
for complete typed results and exactly-once execution; aggregate
per-worker ingress-claim, owner-local, direct and stolen execution
source counts reconcile with accepted/completed totals.

Each task's actual execution worker index is reconstructed from
its OS thread ID against the worker's *joined* profile snapshot.
The research process outputs stable pool slot numbers only.
The `claims.csv`, `tasks.csv` and `siblings.csv` full
event files are produced by CI and included in its artifacts
(retention controlled by the workflow); the permanent Git
CSV above contains **derived CI console summary fields**,
not the entire child-event detail.

## First-phase observations

There are exactly **32 hosted scenario rows**.

| Condition | Cases | Observation |
|---|---:|---|
| 4 blockers / 4 workers | 16 | **15/16** started all four blockers by 60 ms |
| 4 blockers / 4 workers | 1 of 16 | ARM64, GC, `waiter`, round 1: **only 3/4** had started |
| 4 blockers / 4 workers | 16 | **0 sibling starts after the last blocker started and before gate release** |
| 3 blockers / 4 workers | 16 | **21 total** sibling starts after the last blocker started and before gate release, across the 16 small process runs |

The 4-blocker anomalous case is evidence of a **delayed
accepted-to-execution start** under this particular burst
interleaving. After external gate release, the pool joined with all four
blockers and all eight sibling tasks completed (some sibling tasks
had executed before release); that child passed the exact execution
and typed-result checks.
The data do **not** prove persistent starvation, dropped tasks,
or that the withheld blocker resided in a particular owner's
deque: only event timestamps, actual executing worker and
per-worker aggregate claim/source counts are recorded.

### Critical temporal interpretation

It is possible to observe four blockers **started by the
snapshot** and, say, four to eight sibling tasks **already
completed before gate release**. That does **not** imply
extra tasks progressed while all four workers slept on their
semaphores. Most sibling executions can precede the last
blocker's callable start. The new per-sibling timing channel
distinguishes these event phases.

For the **16 fully blocked worker-count scenarios**, no
sibling began after the last blocker-start event and before
release. For the **16 three-blocker scenarios**, the fourth
worker remained available, and some later sibling starts
were observed. This is consistent with fixed-pool capacity
but still not a kernel-level proof of which thread was
asleep at each tick: a blocker timestamp is captured
immediately **before** it invokes `Semaphore.wait`.

The earlier one-off hosted startup failure from the first
burst-blocker test therefore remains a real warning against
conflating **admission with prompt start**, but it does
not establish a universal 10-second stall. The deliberately
short present 60 ms observations are **not** a high-percentile
task-start guarantee.

## Metric boundary and decision

`ingressClaimedTasks`, `ownerLocalExecutions`,
`directIngressExecutions`, and `stealExecutions` are
recorded **per worker** and aggregated after join.
They do not causally identify the claimant of every
individual task, the owner of a stolen record, queue
residency duration or notify-to-run delay. Task execution
worker identity is exact, but claim ownership for the
*individual task* remains an unresolved instrumentation gap.

**KEEP**: current task ownership, submission, condition
generation, close/join, typed result contract and GC/always
production defaults.

**DEFER**: increasing ingress batches, changing victim order,
notifier coalescing, busy spinning, expanding worker threads,
promoting `waiterAware` and redesigning `TaskHandle.get()`.
There is no valid cross-platform performance win, latency
or fairness improvement established in this dataset.

**Next gate:** run the native Dell-XPS five-round protocol,
preserve all six generated research artifacts
(`raw.csv`, `claims.csv`, `tasks.csv`, `siblings.csv`,
`summary.csv`, `environment.txt`) and compare
time-ordered task placement with the full worker-claim
counts. If a real harmful task-residency mechanism is
repeatable, design one limited A/B candidate under
explicit forward-progress, idle CPU, fairness,
p95/p99, backpressure, shutdown and DMD/LDC correctness
requirements.
