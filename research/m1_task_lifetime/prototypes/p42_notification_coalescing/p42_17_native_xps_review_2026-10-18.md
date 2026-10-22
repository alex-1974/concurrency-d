# P42.17 — source-pinned native XPS flow-capture review (2026-10-18)

**Decision: KEEP bounded research evidence; NO-GO for conditional notification
production promotion.** PR #38 remains Draft, ADR-0001 remains Proposed.
No public API, production scheduler, or `develop` modification is authorized.

## Native archive and validation

User-provided complete archive `p42-17-xps-01.tar.gz`, SHA-256:
`7d60af1e2ef23e7ab296d638509dece06b88a4d90336dad5743ba4649ec6c12b`.
`commit.txt` pins this capture to
`52c43a37a026a7c8aa69975d47c5976dc7302c75`; recorded tracked-worktree
status is empty (the runner used `git status --porcelain=v1 -uno`, which
does not inspect untracked files). The native compiler is **LDC 1.42.0**
(DMD frontend 2.112.1, LLVM 19.1.7), DUB 1.40.0. Host: Linux
6.17.0-22-generic, Intel i7-9750H, six physical/twelve logical cores.
UTC interval: 2026-10-18 08:42:36–08:42:45. Both release binaries and
both build logs are present.

Independent SHA-256 verification: **2/2 binaries** match the
`binaries.sha256` manifest, and **39/39** raw/CSV files match
`results.sha256`. The archive includes `sources.sha256` but not the
corresponding raw source bytes: its source hashes cannot be independently
recomputed from the archive alone. GitHub Actions
[#39112089915](https://github.com/alex-1974/concurrency-d/actions/runs/39112089915)
passed DMD 2.111.0 and LDC 1.41.0 on the same source commit. Native LDC
1.42.0 is **not** the CI compiler version.

An independent raw-text audit, separate from the repository extractor,
validated all **36** arm logs = three sessions x six alternating-arm pairs
x two arms, **15,984** task records, **1,296** rounds, and **1,296**
publication-flow observations. It independently rechecked the four
simultaneous waiter enrollments per round, task uniqueness/worker IDs,
nonnegative exact timestamp differences, per-round distribution, all
publisher/notification and return/predicate accounting laws and PASS
markers. Raw-derived task and flow fields agree exactly with the supplied
CSV files.

## Publication-flow observations (native, descriptive)

| Tasks/round | Arm | Accepted publications | Published with waiter | Without waiter | Publication notify calls | Skips | Wait returns |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | baseline | 216 | 216 | 0 | 216 | 0 | 216 |
| 1 | conditional | 216 | 216 | 0 | 216 | 0 | 216 |
| 4 | baseline | 864 | 864 | 0 | 864 | 0 | 486 |
| 4 | conditional | 864 | 864 | 0 | 864 | 0 | 475 |
| 32 | baseline | 6,912 | 6,134 | 778 | 6,912 | 0 | 1,127 |
| 32 | conditional | 6,912 | 6,250 | 662 | 6,250 | **662** | 1,059 |
| **All** | **baseline** | **7,992** | **7,214** | **778** | **7,992** | **0** | **1,829** |
| **All** | **conditional** | **7,992** | **7,330** | **662** | **7,330** | **662** | **1,750** |

**Direct mechanism evidence:** Conditional skips **662 / 7,992 =
8.28%** of publication-site `Condition.notify()` calls; only in
32-task bursts (**9.58%** of that shape's publications), and in
**67 / 216** conditional 32-task rounds. All skips happen when
`_waiters == 0` at the publication mutex observation. The 778
baseline no-waiter publications were observed under **different
interleavings**, not under a counterfactual matched execution trace.

The conditional arm recorded 79 fewer returns from `Condition.wait()`
(1,750 vs 1,829). This difference **cannot be causally attributed**
to the 662 suppressed publication notifications: workers may return
following local-work announcement, other notifications, or spontaneous
returns. All **3,579** recorded returns across both arms had a changed
tested predicate; none had an unchanged one. This does **not** establish
which signal caused a return, prove OS kernel sleep/wakeup, or establish
the absence of unnecessary wakes. The last snapshot precedes
`closeAndJoin`, so later return events may fall outside it.

## Timings — raw MonoTime ticks only

The per-task interval includes admission, inbox lock contention,
scheduling and the beginning of the task dispatch thunk. It does not
isolate kernel wake latency. No tick-to-time conversion is claimed.

| Tasks/round | Arm | Pooled task median | P95 | P99 |
|---:|---|---:|---:|---:|
| 1 | baseline | 12,975 | 82,471 | 89,881 |
| 1 | conditional | 14,793 | 84,486 | 89,557 |
| 4 | baseline | 12,390.5 | 36,273 | 53,107 |
| 4 | conditional | 14,828 | 41,823 | 87,376 |
| 32 | baseline | 10,832.5 | 37,738 | 63,031 |
| 32 | conditional | 12,021 | 40,123 | 57,139 |

For each of 18 session/pair runs per shape, take the per-file task
median and subtract baseline from conditional. The median paired
differences are **+277.75** ticks (1 task, conditional wins 8/18),
**−653.5** (4 tasks, wins 12/18) and **−787.25** (32 tasks, wins
12/18). Paired and pooled medians can have different signs because
they are distinct statistics; neither qualifies a stable speedup.
For one-task runs, session median paired deltas are respectively
+23,491.5, −22,293.75 and +277.75 ticks. The direction and magnitude
of variation exceed the tiny central paired effect.

23 thermal/frequency snapshots indicate CPU package readings **55–71°C**
and CPU0 instantaneous frequency **approximately 1,000–4,201 MHz**.
These are not continuous per-thread traces and cannot diagnose thermal
throttling; they indicate uncontrolled operating-state variation.
The 3-session protocol has no independent fixed-work common-mode
performance control and neither round nor individual-task data are
independent replicates.

## Conclusion and disposition

- **PASS:** internally coherent, source-commit-pinned native P42.17
  notification-flow diagnostics, validated raw and binary hashes.
- **ESTABLISHED ONLY:** a limited number of publication-site notify
  *calls* are eliminated when **no condition waiter is enrolled**.
- **NOT ESTABLISHED:** avoided kernel wakeups, throughput improvement,
  reduced latency/tail/energy, fairness or starvation freedom.
- **NO-GO:** do not merge conditional notification into production and
  do not ratify ADR-0001 or move PR #38 out of Draft.
- **NEXT:** retain this as a negative/mechanism Research result. Do not
  accumulate additional counters without a new targeted hypothesis.
  Any renewed performance qualification needs semantically identical
  **uninstrumented** consumer-representative release builds, independent
  paired controls, stricter frequency/drift characterization and a
  specified minimum useful effect size.

The full original evidence is preserved outside repository Git history
by its archive SHA-256. The independent audit yields `summary.csv`,
`paired_runs.csv` and `independently_parsed_flow.csv` (derived results,
not new native measurements).
