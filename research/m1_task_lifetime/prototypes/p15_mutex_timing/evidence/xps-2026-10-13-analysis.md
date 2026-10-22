# P15 — Dell-XPS mutex timing research: native control versus timed M0 (2026-10-13)

**Status:** Original archive fully examined and internally validated. **GO** to preserve diagnostic evidence and investigate central synchronization further; **NO-GO** for attributing uninstrumented mutex costs, changing production completion semantics, shipping a general `@safe` TaskScope or claiming C++ parity.

## Exact provenance and privacy

- User-supplied original `p15-xps-2026-10-13.tar.gz`, **365,031 bytes**, **SHA-256 `5423ea7385445f5487fa289b24a59fe5f3e0719ae3a2200e41f845376c2910d0`**. The original archive and its raw manifests/logs remain in the research exchange and were **not uploaded to public GitHub**, because they include host/user/local-path information.
- Manifest measured **commit `fb0147d6f44183b0eae7e3ccfbc48cf4c7e0c734`**, M0 source blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, LDC **1.41.0** based on DMD 2.111.0 / LLVM 19.1.7, DUB **1.40.0**, whole-DUB **release** build. Real production `SubmissionWorkerPool` is the control; timed mode uses the reviewed exact-source, differently named P15 research clone.
- Hardware: Dell XPS 15 / Intel Core **i7-9750H**, 6 physical cores / 12 logical threads. Process CPU affinity **0,1,2,3** corresponds to **four distinct physical cores** in recorded `lscpu -e`. This is a process mask, **not per-worker thread pinning**; OS scheduling/migration still applies.
- The manifest has system/optional `sensors` snapshots, but **no continuous CPU frequency/thermal trace, PMU counters, or uninstrumented kernel-lock profiling**. Whole-process A/B order alternates: session 1 `control→timed`, session 2 `timed→control`, session 3 `control→timed`.
- Generated P15 timing/source fixture [design and exact measurement scope](../README.md). CSV-derived anonymized numerical summaries are available in the research exchange; the exact original archive is identified by its SHA-256.

## Original-data verification

- Three sessions, **45 combinations** = 1 / 2 / 4 workers × 0 / 8 / 32 / 128 / 512 scalar iterations × ingress capacities 8 / 64 / 256.
- **Every mode per session:** 2 full warm-up sweeps and 7 full measured sweeps, 405 rows. Total = **2,430 rows** = 540 warm-up + **945 uninstrumented controls** + **945 timed research variants**.
- A record is **3 waves × 2,048 Tasks = 6,144 accepted and completed tasks** in one pool with native workers retained across the waves.
- Checked: complete scenario grid on every sweep, no duplicate configurations, valid execution-order positions, equal randomized `seed/phase/round/order/workers/count/waves/iterations/ingress` and checksum **in each corresponding control/timed row**, fixed checksum by kernel, nonnegative measured intervals, and **exact** `prepare + pool_start + waves + join + verify = total` for every sample.
- Control reports **zero** lock-timing fields. In every timed sample, **`complete_calls=6,144`**, **`submit_calls=6,144+retries`**, at least one inbox takeBatch, nonnegative accumulated durations, and max wait/hold no greater than the associated sum. This is **internal trace integrity** backed by existing explicit P13 per-task oracle and accepted/completed tests, not a native-failure injection or new ownership proof.

## Uninstrumented M0 scaling survives into P15

Use **only control-mode `waves_ns`**, which excludes record preparation, pool startup, final native join and oracle verification. For each kernel, divide 4-worker by 2-worker `waves_ns` **within the same shuffled sweep and ingress**; there are **63 comparisons per kernel** (3 sessions × 7 sweeps × 3 ingress capacities).

| Kernel iterations per task | Median 4w / 2w control | Four-worker wins / 63 |
|---:|---:|---:|
| 0 | **1.696×** | **0** |
| 8 | **1.612×** | **0** |
| 32 | **1.501×** | **0** |
| 128 | **1.176×** | **9** |
| 512 | **0.912×** | **46** |

This reproduces the previous P13/P14 **granularity crossover**, independently of P15's invasive timing path. The uninstrumented 4w/2w ratios at 0 iterations, by session, are about **1.81 / 1.64 / 1.70**; the session-specific 512-iteration medians are **0.92 / 0.87 / 0.92**. It is credible as *this-workload* scaling on the XPS; it cannot establish the individual cost of any lock, a universal worker default, or C++ parity.

## The probe strongly perturbs M0

All **945 matched measured A/B samples**, analyzed as `timed.waves_ns / control.waves_ns`, show:

- **Overall median 2.145×**; 10th–90th percentiles approximately **1.433×–3.396×**. Two of 945 timed runs happen to be faster than their control due to scheduling/noise; this is not an instrument win.
- Session medians **2.231× / 2.203× / 2.011×** (alternated process order). Their values and direction are not constant enough to support a universal multiplicative correction.
- Medians by **kernel**: **2.747× (0), 2.739× (8), 2.453× (32), 1.853× (128), 1.732× (512)**. As predicted, per-task timestamps and longer existing critical sections dominate relatively more for small kernels.

**Do not subtract `sum(wait_ns)` from control wall time**, multiply observed durations by an invented trace-overhead correction, or claim the timed-mode lock data quantify the original uninstrumented implementation. In P15 the probe performs `MonoTime` calls immediately before entry, inside the lock, and on scope exit while still locked. The final statistics increment/storage and mutex release occur **after** the recorded hold endpoint; those steps still lengthen the real critical section and thus interfere with concurrent acquisition. An acquisition interval also includes timestamp and OS scheduling effects, not only hardware/OS mutex-blocked time. Aggregated wait durations across several threads overlap and can exceed the measured wall interval.

## Specific acquisition/hold diagnostic — 6,144 zero-iteration tasks, ingress 64

Below are **medians across 21 timed measurements per worker count** (three sessions × seven sweeps), computed **within each run** as `site_total_wait_ns/site_calls` and `site_total_hold_ns/site_calls`, then taking the median of those run-level means. These are *perturbed intervals* in the **TIMED** M0 clone, not calibrated production-Mutex cost.

| Site | 1 worker wait / hold (ns/call) | 2 workers wait / hold | 4 workers wait / hold |
|---|---:|---:|---:|
| `trySubmit` | **1,144 / 137** | **856 / 173** | **1,590 / 449** |
| `takeBatch` | **631 / 282** | **1,267 / 231** | **2,781 / 204** |
| `completeOne` | **781 / 97** | **964 / 87** | **2,662 / 107** |

The **`completeOne` call count remains exactly 6,144 at every worker count**. In the *timed clone*, increasing to four workers is associated with much larger **acquisition intervals** for completion and batch draining, while the observed body intervals remain comparatively short. This is **consistent with contention around the shared lock**, but the probe's own extra critical-section work can *create or magnify* that contention. It does **not** prove that four workers in the untouched M0 spend 2.66 µs waiting for their original completion mutex.

At ingress 64 and **512 kernel iterations**, the completion wait/hold medians are approximately **646/123**, **1,418/137**, and **3,376/140 ns per call** at 1/2/4 workers. The longer *timed* wait at four workers persists even though in **unchanged-control** execution four workers usually outperform two. This is a particularly important warning against treating these intervals as direct explanations of overall control performance.

**Tail warning:** At 0 iterations/ingress 64, median of each run's worst `completeOne` acquisition interval is about **33 µs (1 worker), 62 µs (2), 250 µs (4)**, with occasional much larger maxima. A max per 6,144 calls is a noisy extreme-order statistic involving possible thread preemption, not an intrinsic lock-service-time distribution.

## What the five sites and call counts establish

- `trySubmit`: attempts are `6,144 + full retries`, so very small queues or long tasks can increase acquisition frequency from repeated submission. Retrying under backpressure is semantically necessary in the existing interface; a faster variant must preserve `accepted/full/closed` distinction.
- `completeOne`: **exactly one common inbox critical-section entry per completed TaskRef** under original M0 rules. The timed data can show how often this specific source path is exercised; it cannot show whether replacing the lock with atomics is safe without a separate event/wake/ownership proof.
- `takeBatch`, `wakeGeneration`, `announceLocalWork`: worker visits to the same mutex increase with the number of workers and task granularity. At 0 iterations / ingress 64, median takeBatch calls in timed mode were roughly **798 (1 worker), 1,266 (2), 2,657 (4)**. Their lock traffic and scheduler interleavings compete with submit/complete.
- `parkUnlessChanged` (Condition.wait) was **deliberately not timed as a lock hold**, since the lock is released during the wait. P14's park-count evidence remains the relevant observation until a separately defined wait/wake timing protocol is qualified.

The correlation strongly supports continuing to investigate the **single shared TaskInbox synchronization point**, with **completion and ingress/batch activity considered together**. It does **not** isolate completion as the *sole* or *dominant* cause. There are interacting producer, worker-deque, waiter and notification paths.

## Decision, follow-up and non-goals

**PASS:** P15 native archive integrity, matched control/timed source workload and result semantics, exact lock-entry conservation, repeated randomized control scaling, and credible *timed-clone* acquisition/hold observations.

**KEEP as a narrower research hypothesis:** at very short tasks, a high-frequency common inbox mutex is a plausible contributor to the 4-worker slowdown; the invasive timed clone reports longer acquisition intervals as worker count rises.

**DEFER:** any production replacement of per-task completion counting, lost-wake protection, native join/start failure policy, batch/steal policy, default worker count, generic public `@safe` claims, or direct D-vs-C++ speed assertions.

**Next bounded study (P16 candidate):** calibrate the clock/probe overhead independently; use an **uninstrumented** M0 run with optional Linux `perf stat` events (e.g. task-clock, CPU cycles, context switches, migrations, cache and CPU frequency if available) and/or an isolated variant that instruments only **one** mutex site with per-thread buffer/sampling. Separately, if investigating an alternative completion policy, compare two **uninstrumented** research copies with identical `accepted/completed/close/park` predicates, exact Thread.join lifetime obligations and checked results; add adversarial completion/close/park races and fault probes before any `@trusted` or public `@safe` consideration. This is strictly research; source, production manifest, `develop` and grandfathered R0.5 remain untouched. ADR-0001 **PROPOSED**, Issue #17 **OPEN**, Draft PR #38 **DRAFT**.
