# R0.5 — Dell XPS burst head-of-line qualification (2026-10-11)

**Decision: KEEP** the current unconditional-notify (`always`) and
fresh-GC record storage baseline; **DEFER** any scheduler, task
ownership, work-stealing, ingress batch-size or public-API change.
This is research evidence, not a throughput or fairness gate.

## Provenance

User-supplied, unmodified archive
`r05-xps-burst-head-of-line.tar.gz`:

| Original object | Bytes | SHA-256 |
|---|---:|---|
| Archive | 7,242 | `961a1fcc068601544f588f8a58261b2660c83b9d669e8bc82a084430fa1c10c4` |
| `raw.csv` | 2,471 | `7beb43d89420f6e6a8643ea3bbdd618c1d5e86e82a1d31eed65ee090cc9c222f` |
| `claims.csv` | 6,139 | `aa8d2024062adcd7cf9f46aecfcdd9d6fd998273e0eb96ae20f29f50e29ff04f` |
| `tasks.csv` | 4,972 | `e2abf330612357dbf7703c4a6b231d1303abf8d6074b72f4daa363964871e8d8` |
| `siblings.csv` | 12,755 | `e336f3fcaa63eb73219ebc2734151b3a0dc5a2b5998357dec581e054d22ccecc` |
| `summary.csv` | 477 | `c129ba07474125d6d68ce986555c3f0208e100973ee0a26088258ffe0cf11e29` |
| `environment.txt` | 5,505 | `9c117636711c35f04c80ef30a075954f07c51d468722d204d796a771596ce412` |

Each input was parsed from the archive without executing its content.
The `environment.txt` records the exact **measured code SHA**
`5e346b3c016a99796882dfb9a415910128de331d`,
**LDC 1.41.0** (DMD frontend 2.111.0, LLVM 19.1.7),
Linux 6.17.0-22-generic, glibc 2.43, and Intel Core
i7-9750H (6 physical / 12 logical processors).
The archive does **not** establish a controlled CPU clock,
temperature or power budget. Do not reuse the earlier session's
`powersave` observation as if verified in this session.

Fixed parameters: **four workers, eight runnable siblings**, three
or four semaphore-blocking tasks, **100 ms** external
`Thread.sleep` observation, five paired rounds,
`gc`/`recycle` and `always`/`waiter`. The benchmark
releases every blocker externally, then validates exact typed
results and closes/joins.

The original user archive is the **authoritative lossless evidence**
for all six files. Permanent Git evidence on this grandfathered
research branch includes:

- [All eight exact source group summaries](./xps-burst-head-of-line-2026-10-11-summary.csv)
  (the only transformation is CRLF to LF; verified Git blob
  `67cefa610ed04aea42b34acc165d14a243496f04`).
- [All 40 joined scenario diagnostics](./xps-burst-head-of-line-2026-10-11-reconciled.csv)
  (derived from original `raw.csv`, `claims.csv`,
  `tasks.csv`, `siblings.csv`).
- This report, with original archive/member SHA-256 values.

The joined CSV is **not** a lossless substitute for all 160
per-worker and 460 per-task source records. Retain the
original six-member archive as the source for any future
task-level reanalysis.

## Independent conservation audit

| Source | Rows | Columns |
|---|---:|---:|
| `raw.csv` | 40 | 16 |
| `claims.csv` | 160 | 12 |
| `tasks.csv` | 140 | 9 |
| `siblings.csv` | 320 | 9 |
| `summary.csv` | 8 | 12 |

All **40** experiment keys
(round, storage policy, notification policy, blocker count)
are unique and complete:
`5 rounds × 2 storage × 2 notify × 2 blockers = 40`.

For **every** experiment:

- All worker slots 0–3 occur exactly once in the claim file.
  Blocker IDs and sibling IDs have no gaps or duplicates.
- All four worker claim totals add to **11** tasks
  (3 blockers + 8 siblings) or **12** tasks
  (4 blockers + 8 siblings), exactly as reported by the
  optimized D benchmark.
- Summed per-worker `executions` match the accepted task count.
  For each worker, `local_executions + direct_executions +
  stolen_executions = executions`.
- Blocker and sibling `started_before_release` counts
  reconcile with the original `raw.csv` event totals.
  Per-task worker indexes are valid, and the count of distinct
  blocker-execution workers matches `distinct_workers`.
- `siblings_after_all_starts` recomputes exactly from
  individual blocker/sibling start times and before-release
  flags, using the same definition as the source script.
- All **eight** five-round summary medians and complete-start
  counts recompute without discrepancy.

**No lost, duplicated or incomplete typed task execution was
reported by these successful child processes.** This does not
prove full scheduler deadlock/starvation freedom.

## Observed phases of the burst

Across 20 sessions with each blocker count:

| Event | 3 blockers / 4 workers | 4 blockers / 4 workers |
|---|---:|---:|
| Complete blocker startup within 100 ms | 20/20 | 20/20 |
| Siblings executed before gate release | 85/160 | 80/160 |
| Siblings started **after latest blocker-start** but before release | **27** | **0** |
| Distinct executing blocker workers | 3 in all runs | 4 in all runs |

Every one of the **27** later sibling starts in the
3-blocker condition was executed by the remaining,
non-blocked worker. When all four blockers had started,
no additional runnable sibling began before external release,
consistent with a non-compensating fixed thread pool.
A blocker start timestamp is recorded immediately **before**
`Semaphore.wait()`, not upon confirmed kernel sleep.

Crucially, siblings completed before release in the
4-blocker condition may have executed *before the last
blocker started*. This cannot be called progress by
four blocked workers.

### 3-blocker condition: where were 75 delayed siblings?

The 160 runnable siblings are partitioned by
`started_before_release` and whether the executing worker
**also executed one of the three blocker tasks**:

| Sibling start | Executing worker class | Tasks |
|---|---|---:|
| Before release | Worker that also ran a blocker | 58 |
| Before release | Worker that ran no blocker | 27 |
| **After release** | **Worker that also ran a blocker** | **72** |
| After release | Worker that ran no blocker | 3 |
| **Total** | | **160** |

- **19/20** three-blocker runs retained at least one
  sibling until release that later executed on a
  previously blocked worker.
- In **19/20** three-blocker runs the sole non-blocker
  worker had `0` recorded **inbox claims**.
  The exception is GC/always, round 1, where this
  worker directly claimed eight sibling records and
  all eight completed before release.
- In **18/20** three-blocker runs, at least one worker
  accumulated **eight or more inbox claims**.
  These counts aggregate multiple batches; a run with
  nine cumulative claims does **not** mean one claim
  exceeded the implementation's maximum batch size eight.
- Across both storage policies and both notification
  variants, the **median** siblings completed before release
  was four of eight; the median count started after the
  final blocker-start but before release was one.

**Interpretation:** the conjunction of a single worker
concentrating ingress claims, a non-blocked worker usually
claiming no inbox tasks, and **72** delayed siblings
eventually executing on previously blocked workers is
strong *correlational* evidence for a potential
**owner-deque head-of-line** mechanism.

**Causal limit:** per-worker claim metrics are aggregate,
not per-TaskRef. We cannot identify the *individual*
claimant, claim timestamp, deque residency time or
which victim supplied a stolen sibling. Some tasks
could have been stolen after release. Consequently,
**do not claim every one of the 72 tasks was physically
queued behind a blocker in the same deque**, or that
a free worker was idle throughout the 100-ms window.
The result justifies a more discriminating probe, not
an immediate queue algorithm change.

## Policy comparison and performance interpretation

The [source summary](./xps-burst-head-of-line-2026-10-11-summary.csv)
has **identical median counts** across `always` vs
`waiter` and `gc` vs `recycle` for a given number of
blockers. All **40** runs started their blockers before
release. The size of the post-start sibling pool
varied between individual rounds. One GC/always/three
blockers run completed all eight siblings before
release, while most three-blocker runs completed
three to five.

The benchmark is **not** a fair throughput A/B:
profiling and per-task start timestamp atomics run in
both variants, and a forced 100-ms blocking interval
dominates child wall time. It did not measure p95/p99
queue latency or idle CPU under controlled frequency.
No notification, storage or work-stealing **speedup**
is supported by these observations.

## Engineering conclusion and next smallest experiment

**KEEP** the current fresh-GC baseline and
generation-safe unconditional condition-variable
notification and the existing accepted/completed
shutdown and result contract.

**DEFER** promoting `waiterAware`, typed record
recycling, increasing batches, changing steal order,
spinning, blocking-compensation threads or a
help-while-wait user-visible guarantee.

**NEXT:** use an opt-in, bounded per-TaskRef tracing
experiment to record, for each task:

1. producer publication time;
2. exact inbox claiming worker and claim time;
3. owner-deque enqueue (if applicable);
4. deque pop or steal with executing worker and
   victim/owner ID;
5. callable start time, before semaphore entry;
6. task completion and externally controlled release.

Use an isolated trace mechanism with known overhead,
an uninstrumented throughput control, and guaranteed
release and close even if work stays pending. Contrast
the current max claim size eight with a strictly
single-task claim **only if** that evidence identifies
the local deque as the source of the observed delay.
Evaluate p50/p95/p99 task-start delay, idle CPU,
throughput, fairness, forward progress and exact-once
lifetime guarantees on DMD/LDC/native platforms.

This is a research recommendation, **not authorization
to alter the production scheduler**. Keep [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
open as grandfathered experimental history; do not
merge wholesale to `develop`. Tracked by
[Issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
