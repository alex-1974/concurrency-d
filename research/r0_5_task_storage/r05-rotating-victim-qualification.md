# R0.5 — Complete foreign-victim search with rotating first victim

**Status:** active, **research-only**. The public library still uses
`IngressBatchSize=8`, `OwnedRecordPolicy.freshGc`, and
`NotificationPolicy.always`; no default scheduler or public API changes.
PR #35 stays Draft and issue #20 open.

## Motivation / controlled hypotheses

The native XPS [complete-sweep review](results/xps-victim-sweep-review-2026-10-11.md)
isolated a concrete coverage problem: the historical N−1 candidate-position
steal loop skipped `self` and could miss an entire other worker's deque
before parking. In the 4-worker / 3-blocker native experiment, changing
**only** to N candidate positions (retaining batch8) raised the count of
siblings started before external gate release from 102/160 to 160/160.
However, in the complete N-position loop, after *every failed* sweep
the cursor returns to the same start victim. This is a potential
starvation/fairness weakness for repeated searches, even with full
coverage.

Three independently compiled variants, all with unchanged task ownership,
storage and task execution:
1. `old`: original **N−1 candidate positions**, possible omission;
2. `full`: **N positions**, complete coverage, fixed start after failure;
3. `rotating`: **N positions**, complete coverage, after failed scan
   advance to the next **foreign** initial victim (skip self).

The rotating variant also normalizes `nextVictim` to a foreign worker at
the start of any search if a previous **successful** steal left it
pointing at `self`. For N>1, a sequence of N−1 fully failed
searches visits **each foreign worker exactly once as the first
attempted victim**. N=1 has no eligible foreign victims and remains
well-defined. No additional synchronization, allocations, fence,
queue API, or task lifetime change is introduced. All logic is behind
`version(R05RotatingFullVictimSweep)`.

**Important:** this is *scan-first fairness under repeated fully empty
searches*, not a scheduler fairness guarantee for concurrent task
injection, priority, order of runnable tasks, or blocked worker
progress. LIFO owner-pop and FIFO thief steals remain as before.

## Deterministic test and correctness gates

`tools/research/r05_rotating_victim_matrix.py` first executes a
deterministic cursor-model test for worker counts 1,2,3,4,5,8,16,32
and all self IDs/starting victim indices. It rejects duplicate or
missing foreign victims and non-uniform first-foreign rotation across
N−1 consecutive failures. It also checks that the original
N−1-index omission is reproducible.

The actual D build and benchmark then exercise:
- exact accepted/completed/claimed task conservation;
- correct, exactly-once typed/void results and GC-visible captures;
- 3/4 blocking workers; actual per-sibling starts and external gate;
- 1/2/4/8/16 worker scaling for mixed workloads and idle;
- 1/4/8 real producers (where selected), `gc/recycle`,
  `always/waiter`, `minimal/compute`;
- safe close/join and zero pending task-record retention;
- no per-task recorder in performance variants.

CI uses one bounded smoke round across DMD 2.111.0 / LDC 1.41.0 x86
and LDC 1.41.0 ARM64. Hosted timings are never release thresholds.

## Native repeated measurement protocol

The three-way runner builds nine separate **release** executables
(old/full/rotating × burst/mixed/idle). Builds are excluded from each
measurement. Fresh child processes are run in a deterministic,
factor-dependent rotating order. At identical batch8, the following
separate evidence is recorded:

- `burst_cases.csv`, `burst_siblings.csv`: exact external gate,
  actual callable start timestamp and last-blocker start, who executed
  each sibling, per-run p50/p95/p99 offsets **from burst start**, not
  per-task submit-to-start. With four completely blocked workers,
  no generic progress guarantee is possible.
- `mixed_cases.csv`: internally timed complete multi-producer
  execution, workload checksum, typed results, record lifetime,
  whole-child CPU and context switches; 100k tasks by default.
  `compute` invokes the existing benchmark's 1024 rounds per task.
- `idle_cases.csv`: **process CPU consumption during a quiet
  interval after worker startup**, actual quiet wall duration,
  low-arrival-rate typed task response p50/p95/p99, context switches.
  CPU fraction is normalized against **one CPU core**. It is not a
  per-worker energy estimate or a battery-power reading.
- `pairs.csv`: all within-round full/old, rotating/full,
  rotating/old contrasts, preserving factor identities and zero ratios.
- `summary.csv`: medians of **paired contrasts**, not ratio of
  unrelated medians.
- `environment.txt`: exact Git SHA, compiler/platform/CPU and
  available CPU-frequency governor.

The separate `worker_search` tracer is intentionally not enabled for
performance cases. The prior native instrumented mechanism study remains
available in the previous review; a new per-task mutex would invalidate
the throughput comparison.

The current runner does **not** pin CPU affinity or control governor,
thermal throttling, scheduling interference, or process-level warmup.
Interpret small throughput ratios conservatively. The idle sampling
includes the controlling process/thread's cost within the quiet interval.
A proposed production change must withstand repeated native XPS
measurements and separate profiling under target conditions; no blanket
speedup can be inferred from one short CI run.

## Dell XPS reproduction

From an unchanged local checkout, preserve any uncommitted work before
switching branches, then `git fetch origin`,
`git switch perf/r05-owned-task-pipeline`,
`git pull --ff-only origin perf/r05-owned-task-pipeline`.

**Step 1: production-default storage/notification controls;**
a 3-way test of worker scaling, CPU and idle:

```bash
python3 tools/research/r05_rotating_victim_matrix.py \
  --compiler=ldc2 --rounds=5 --tasks=100000 \
  --workers 1 4 8 --producers 1 4 \
  --blockers 3 4 --burst-ms=100 \
  --policies gc --notify always \
  --workloads minimal compute --budget=512 \
  --idle-ms=300 --wake-samples=64 --gap-ms=1 \
  --output=evidence/r05-xps-rotating-default
```

**Step 2: storage/notification controls** without multiplying
the first run's whole matrix:

```bash
python3 tools/research/r05_rotating_victim_matrix.py \
  --compiler=ldc2 --rounds=5 --tasks=100000 \
  --workers 4 --producers 1 4 \
  --blockers 3 4 --burst-ms=100 \
  --policies gc recycle --notify always waiter \
  --workloads minimal compute --budget=512 \
  --idle-ms=300 --wake-samples=64 --gap-ms=1 \
  --output=evidence/r05-xps-rotating-controls
```

Preserve both evidence trees, including all CSVs and environment files:

```bash
tar -czf r05-xps-rotating-victim.tar.gz -C evidence \
  r05-xps-rotating-default r05-xps-rotating-controls
```

## Decision gate

**Pass/fail semantics** first: no duplicate/lost results, correct
accounting, stable memory lifetime and shutdown, portable DMD/LDC
including native ARM64. Compare 3-blocker p95/p99 and actual
post-final-blocker progress without falsely claiming four-blocker
progress. For repeated fully failed searches, rotating first-foreign
coverage must hold mathematically and empirically without higher
idle CPU or outlier wake latency.

Evaluate throughput as **paired within the same workers/producers/
storage/notify/workload/round**, including 1,4,8-worker scaling,
resource and context-switch cost, and stability over repetitions.
Investigate any x86-vs-ARM divergence or regression before promotion.

**No automatic default change, merge of Draft PR #35, issue closure,
`develop` write, or edit to `containers-d`** is authorized by
research-smoke results alone. A selected, reviewable scheduler fix
should eventually have a separate narrowly scoped promotion decision.
