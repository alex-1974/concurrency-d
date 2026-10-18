# P42.18 — paired, uninstrumented end-to-end replication

**Status:** research experiment only; design and CI checks precede any native
measurement. **Inherited decision:** P42.17 showed that 662 publication-site
notifications were avoided in its fully instrumented four-worker diagnostic,
but did not establish a consistent performance improvement or kernel-wakeup
reduction. Do not use P42.17's instrumented task-start ticks as a speedup
baseline. Keep PR #38 Draft; ADR-0001 Proposed; M0 production unchanged.

## Research question, competing explanations and scope

**Question:** Does the source-derived conditional publication-notify policy
produce a repeatable and practically useful improvement in **complete
pool creation, producer submission, worker execution, and close/join**
under equal work and a consumer-representative LDC release build?

Competing explanations include input/task-cost dependence, core frequency,
OS scheduling variability, branch-order effects, changes in producer
contention, and unnecessary publication notifications.

This intentionally **reuses the pre-existing**
`research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p42_benchmark.d`,
not the P42.16/P42.17 time-stamped or worker-TLS consumer. Work is verified
after timing: each admitted record executes exactly once, and accepted and
completed counters equal the input count. Medium work adds exactly 32
observable relaxed atomic increments per task; Light adds one hit increment.
The two policy variants execute the *same code and identical work within
each cost*. The benchmark's `StopWatch` measures elapsed microseconds.

Baseline imports the **unchanged production**
`concurrency.internal.submission_pool`. Conditional imports the original
P42.6 **legacy source-derived overlay** via the generator's existing
two-argument invocation: its additional inbox `_waiters` counter is required
for the policy. "Uninstrumented" here means **no P42.16/P42.17 diagnostic
TLS, snapshots, task timestamps, flow vectors or per-worker tracing**.
It cannot mean identical instruction sequences or no waiter bookkeeping
on the conditional side; the waiter counter is itself an intrinsic part
of this proposed policy.

## Fixed experiment matrix

- Compiler: XPS LDC version pinned and recorded verbatim; both arms use
  the **same** `dub build --compiler=ldc2 --build=release --force` invocation
  and identical non-arm-specific optimization flags. Four explicitly named
  DUB configurations select only `P42Baseline`/`P42MediumTask` versions.
- Work/cost: Light and Medium; **131,072** successfully admitted tasks per
  process; ingress capacity 256, originally implemented retry-on-full;
  verification occurs after `StopWatch.stop()`.
- **Target workload:** 4 producers / 4 workers. **Secondary temporal
  control:** 1 producer / 1 worker, using the same TaskRecord semantics,
  number of tasks, task cost and binaries.
- Warm-up: two untimed runs per each of four binaries and two workload
  shapes, prior to measured runs. Distinct arm binaries are prebuilt and
  hashed before any warm-up.
- Repetitions: six independent sessions x six session-local paired cycles x
  two costs x two workloads x two policies: **288 process runs** total,
  **144 arm pairs**, **12 session/cost summaries**. Each arm appears first
  and second by parity; workload order and cost order are balanced across
  runs. All 288 **unmodified original stdout files** are retained.
- Capture complete **git commit, tracked-worktree status, generator/source/
  consumer/DUB/runner/analyzer hashes, exact build logs, binary hashes,
  compiler and DUB versions, CPU/OS, session/pair thermal, CPU frequency,
  governor, affinity and CPU-pressure snapshots**, plus exact UTC start/end.
  No automatic affinity/governor/clock changes (record any external controls).

The control is **not policy-free**: 1P/1W still calls conditional or
unconditional notification. It diagnoses whether apparent 4P/4W gains also
appear in a different concurrency regime under the same environment;
it is **not** a trustworthy normalization oracle. A control effect
similar to the target effect is a *reason to investigate*, not a license
to subtract it from consumer-visible latency.

## Parser and pre-registered interpretation rules

`m1_p42_e2e_analyze.py` checks all filename dimensions and pairs, exactly
one `P42_BENCH` line per raw file, positive elapsed microseconds, expected
worker/producer/task dimensions, and exact raw-to-`results.csv` equality.
Negative controls reject corrupt run metadata and CSV/raw drift.

`paired.csv` records conditional-minus-baseline microseconds and percentages
for each session/pair/cost/workload; `sessions.csv` reports median per-pair
percentage differences separately for target and control and their
pairwise difference (diagnostic **percentage points**, not an
adjusted/normalized speedup). A faster conditional build has a **negative**
percentage delta. Six intra-session pairs are **correlated**; the
primary replication unit is the six session summaries. Microsecond
measurement is end-to-end benchmark time, **not** notification or wake time.

Before seeing new P42.18 native results, define the *research-only minimum
useful benefit* for 4P/4W at the **Light** task cost as a median paired
improvement of **at least 3%** in at least **5 of 6 session summaries**,
with **no session median regression worse than +2%**. Medium must also be
inspected for regressions (particularly to confirm no systematically higher
overhead), and the 1P/1W control must be analyzed rather than discarded.
These exploratory thresholds cannot substitute for source-level safety or
lifetime evidence. Any candidate effect that is small relative to control
drift or unstable across sessions is **inconclusive** regardless of pooled
medians. A speedup claim requires a further **independent native replicate**
with controlled operating conditions. This protocol cannot qualify
starvation freedom, OS wakeup count, fairness or production lifetime safety.

A negative or inconclusive finding means **archive the evidence and stop
optimizing conditional notify without a new hypothesis**; do not
automatically add more instrumentation. A favorable finding triggers
careful follow-up, **not** automatic ADR acceptance, PR merge or API
promotion.

## CI and XPS execution

Before native execution, require green DMD 2.111.0 and LDC 1.41.0
exact-HEAD CI for the four configurations, both workload shapes, parser
positive/negative fixtures and shell preflight. CI is *correctness* only,
not performance qualification.

From the **dedicated P42 XPS worktree**, on the exact qualified HEAD:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d-p42
git status -sb
git fetch origin
git pull --ff-only origin research/m1-task-lifetime-boundaries
# A NEW, previously nonexistent output directory; do not overwrite evidence.
bash tools/research/m1_p42_e2e_native.sh "$HOME/Downloads/p42-18-xps-01"
tar -C "$HOME/Downloads" -czf "$HOME/Downloads/p42-18-xps-01.tar.gz" p42-18-xps-01
```

Upload the **complete** archive; `raw/` alone is insufficient for
compiler and thermal provenance. Each measurement run emits one stable
`P42_BENCH` output line. This runner intentionally does not run the old
P42.9–P42.17 diagnostic configurations. Previously archived evidence is
immutable and unaffected. The original consumer receives no changes.

## Repository contract

Research-only DUB configurations, runner, parser and protocol plus
CI-only correctness smoke. Do not modify `source/`, released DUB
package metadata, workspace documents, sibling repositories or pre-migration
PR #35. Keep `develop` and PR #38 destination/status unchanged.
