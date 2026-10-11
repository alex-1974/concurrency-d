# R0.5 — Useful worker wakeups: hosted qualification (2026-10-11)

**Research only.** No accepted change to scheduler algorithm, admission,
generation protocol, record ownership or public task API.

## Implementation and correctness

The existing `Condition.wait()` loop now has an opt-in **two-stage
event attribution**. Part one records whether a return still has a
blocking predicate, or the final predicate is satisfied by pending
inbox tasks, a generation-only change, or a drained shutdown. Part
two classifies the next complete worker search as:
local task, inbox task, successful steal, empty search, or drained.

The result is **not** a causal attribution of which `notify()` woke
the thread, nor a duration measurement. Other workers can claim
work after the condition return but before the target worker searches.

Two independent equalities were added to source tests and the
benchmark's optimized runtime checks:

```text
wait_returns = still_blocked
    + exit_inbox + exit_generation + exit_drained

exit_inbox + exit_generation + exit_drained
    = useful_local + useful_inbox + useful_steal
      + no_work + drained
```

There are no new per-event atomics, timestamps or mutex acquisitions.
All counters are local to their worker and aggregated **only after join**.
The opt-in flag remains disabled by default; the original
`parking,...` CSV record and existing work/record/handle semantics
are preserved, while opt-in runs additionally emit `wakeup,...`.

- Exact source qualified: `26617a31afb3e9485d7e820d350caf5ab25e91ed`
  (first implementation developed on the existing grandfathered
  `perf/r05-owned-task-pipeline` research branch).
- [DMD 2.111, LDC 1.41 x86-64 and native ARM64 consumer gate PASS](https://github.com/alex-1974/concurrency-d/actions/runs/38129576716)
- [LDC 1.41 x86-64 and native ARM64 research matrix PASS](https://github.com/alex-1974/concurrency-d/actions/runs/38129576688)
- [All 16 persisted hosted summary rows](./r05-ci-wake-outcomes-2026-10-11.csv)
- [Protocol and Dell-XPS exact reproduction](../r05-worker-parking-protocol.md)

## Initial measured useful-search fraction

Conditions: four workers, 1,200 accepted tasks per child process,
retention budget 512, GC-fresh, work counter layout and compute task
semantics as in earlier R0.5. Two rounds on independent GitHub hosted
x86-64 and native ARM64 runners, **not** the user's Dell XPS.
Medians of two runs. Percentages are based on *completed wait-loop
exits*, not all raw `Condition.wait()` returns and not total tasks.

| Platform | Producers | Workload | Useful next search | Empty next search |
|---|---:|---|---:|---:|
| x86-64 | 4 | minimal | **61.43%** | **38.01%** |
| ARM64 | 4 | minimal | **62.05%** | **37.44%** |
| x86-64 | 4 | compute-1024 | **72.86%** | **23.86%** |
| ARM64 | 4 | compute-1024 | **78.88%** | **19.59%** |

The remainder consists of post-wait shutdown/drain outcomes.
On GC/minimal/4p the median condition waits/task were 0.5971
(x86-64) and 0.6583 (ARM64), with 1.4912 and 1.7396 failed
steal attempts/task respectively.

**Important:** `exit_generation` is a state observed under the
inbox mutex immediately after `wait` and can overlap with a
subsequently **useful** local/steal search; it is not a disjoint
category to be added to percentages in the last two columns.
About 34%–39% of final wait exits were generation-only in these
GC/minimal/4p cases.

## Noise, observer effect and limits

Paired profile-ON / OFF median throughput for GC/4p:
- x86-64 minimal 0.9790×, compute 1.0452×;
- ARM64 minimal 1.0074×, compute 1.0726×.

The sample is short and hosted; signs vary between other conditions,
so no valid speedup is attributable to instrumentation or a changed
algorithm. No scheduling policy changed at all.

Finding "no task in first post-wait search" does **not prove** the
notify was unnecessary. A competing worker may have consumed the
published task. A previously useful wake can also trigger further
work later via steal. All classification checks operate in the
existing generation-safe protocol.

The original Dell-XPS worker coordination evidence (30,000
tasks/process, five rounds) counted frequent waits and low steal
hit rates, but did not record these new wake-to-search categories.
**Do not backfill old XPS rows with inferred wake outcome data.**

## Decision and next gate

**KEEP:** GC-fresh owned task storage; `Condition.wait()`
with generation predicate; ownership, close/drain, task handle
and exact execution invariants on `develop`.

**DEFER:** typed record-pool promotion, notification coalescing,
spin-before-park, and batch/sharded admission until controlled
runtime and latency studies justify a scoped experiment.

**NEXT:** perform five paired runs of the existing
`r05_worker_parking_matrix.py` on the actual Intel i7-9750H Dell XPS,
using 30,000 tasks, 1/4/8 producers, GC/recycle, minimal/compute-1024
and ON/OFF. Preserve `raw.csv`, `summary.csv`, `environment.txt`
and exact revision. Interpret useful search and wasted search together
with worker parks, failed steals, admission capacity, CPU governor,
whole-process CPU/context-switches and per-task latency.
Only if that evidence holds should a single change to notification
policy be proposed, with zero-work idle CPU and shutdown safety gates.
