# P16.2 — Native Dell-XPS original M0 versus seq-cst completion research variant (2026-10-13)

**Result:** Original artifact and exact-work run pairs **PASS integrity**; the seq-cst candidate is **not a uniform throughput improvement**. **KEEP** the source-pinned research and full native evidence; **NO-GO** for promoting the completion variant to production, assuming a fixed per-task saving, weakening memory orders, making public `@safe` task-lifetime claims or asserting C++-level parity. In particular, the target CPU package was at its **100 °C listed high-temperature threshold in every saved before/after session sensor snapshot**; temperature/frequency were not continuously sampled.

## Provenance, source boundary and privacy

- Original user-supplied **`p16-2-xps-2026-10-13.tar.gz`**: **SHA-256 `b56aeb2ee0c0ff3ba49946865b4646ed3d0afae149d7487c74bf1ea7f294758a`**. The original 162-KiB archive contains user/host/path details in raw DUB logs and `manifest.txt`; do **not publish the raw archive** to this GitHub branch. A separate **anonymized 45-case summary CSV** and the derived tables below can be shared.
- Manifest declares source commit **`000ca04d7a4f3d2e63e22826dca75b959c06eb0d`**, exact original M0 Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, LDC **1.41.0** (DMD v2.111.0 frontend, LLVM **19.1.7** on this host), DUB **1.40.0**, whole-program **release** builds.
- Intel **Core i7-9750H** / Dell XPS 15, 6 physical cores, 12 logical CPU threads, process affinity CPUs **0,1,2,3** mapped to four distinct physical cores by the saved `lscpu -e`. There is **no individual worker-thread pinning**, no continuous CPU-frequency or temperature trace, no PMU/mutex-contention profiling.
- Each session uses the same shuffled scenario seed and exact task oracle for both versions but executes the **two binaries as separate processes** in order: **session 1 control→atomic**, **session 2 atomic→control**, **session 3 control→atomic**. The within-session case order is identical; sample ratios are paired by identical scenario, seed and shuffled sweep, **not simultaneous executions**. Process/order, cache, OS scheduling and thermal/turbo effects remain possible.

## Original archive validation

- Six original per-session/per-mode `csv/session*-{control,atomic}.csv` files, **all six corresponding `raw/session*-{control,atomic}.log` files**, three session compare diagnostics, temperature snapshots and original manifest were inspected. **Every normalized CSV matched the CSV output embedded in its corresponding raw log byte-for-byte.**
- 3 sessions × 2 versions × 45 workload combinations × (2 warm-up sweeps + 7 measured sweeps) = **2,430 rows**, comprising **540 warm-ups** and **945 uninstrumented control + 945 uninstrumented seq-cst candidate measurements**. Each of the **54 complete sweeps** contains exactly one of each **1/2/4 workers × 0/8/32/128/512 kernel iterations × 8/64/256 ingress** with all shuffle-order positions 0–44 present and unique.
- Each row represents the same **2,048 Tasks per wave × 3 waves = 6,144 accepted, computed and completed TaskRefs** with the same independent P13 work/checksum verification. All **1,215 corresponding pairs**, including warm-ups, matched `session/phase/round/order/seed/workers/count/waves/iterations/ingress/checksum` exactly. The checksum is invariant across all runs at the same kernel intensity.
- Every row has nonnegative stage durations satisfying **`prepare_ns + pool_start_ns + waves_ns + join_ns + verify_ns == total_ns`** exactly. Both variants retain checked P13 TaskRef oracle, post-execution record-retention and native worker join semantics. The **XPS runner invokes close/last-completion/producer-race tests before collecting timings**, but their standard output is **not retained in the archive**; their passing is supported indirectly by the completed runner and independently by pinned GitHub [CI #38459761896](https://github.com/alex-1974/concurrency-d/actions/runs/38459761896) and [#38460101974](https://github.com/alex-1974/concurrency-d/actions/runs/38460101974), not by an archived XPS race transcript.
- **No injected native Thread.start/Thread.join failure, task-scope escape, GC-safety fault or general `@safe` contract is qualified** by these successful benchmark runs.

## A/B performance interpretation and what “faster” means

The primary measure is **`waves_ns`**: all three real worker-pool submit/execute/wave-completion cycles **excluding preparation, native pool startup, final Thread.join and final result validation**. For each of the **945 measured corresponding pairs**, calculate `R = atomic.waves_ns / original.waves_ns` and report **the median of ratios**, not the ratio of separately computed medians. **R < 1** favors the seq-cst candidate. Because both binaries are uninstrumented, **no P15/P16.1 timer-overhead correction is applied**.

**Overall across all 945 measured pairs:** median **R = 0.9265×**, median speedup as reciprocal **1.079×**, with **592/945** cases favoring seq-cst. The overall ratio range is **0.253×–1.942×**, 10th–90th percentile approximately **0.623×–1.204×**. **The aggregate median is a workload-mix statistic, not an unconditional benefit or a reliable expected consumer speedup.**

### Split by actual worker count

| Workers | N | Median atomic/original R | Candidate wins | Interpretation |
|---:|---:|---:|---:|---|
| **1** | 315 | **0.837×** | **300/315** | Candidate usually faster; no multi-worker completion contention is necessary for the gain. |
| **2** | 315 | **1.028×** | **148/315** | Candidate is slightly slower at median; substantial kernel-dependent reversals. |
| **4** | 315 | **1.027×** | **144/315** | Candidate is slightly slower at median; no uniform repair of short-task scaling. |

Per-session median R: **0.915 / 0.913 / 0.938** for sessions 1/2/3. **1-worker** within-session medians: **0.831 / 0.837 / 0.843**; **2-worker**: **0.981 / 1.053 / 1.059**; **4-worker**: **1.014 / 1.008 / 1.041**. The 2-worker sign changes with session and process order; any claimed small 2-worker regression needs better control.

### Split by kernel intensity

| Iterations/task | N | Median atomic/original R | Candidate wins |
|---:|---:|---:|---:|
| **0** | 189 | **1.054×** | 86/189 |
| **8** | 189 | **1.066×** | 77/189 |
| **32** | 189 | **1.048×** | 81/189 |
| **128** | 189 | **0.642×** | 171/189 |
| **512** | 189 | **0.856×** | 177/189 |

The outcome **depends materially on BOTH worker count and task size**:

| Workers | 0 iter. R | 8 iter. R | 32 iter. R | 128 iter. R | 512 iter. R |
|---:|---:|---:|---:|---:|---:|
| **1** | 0.831 | 0.831 | 0.862 | **0.561** | 0.947 |
| **2** | **1.165** | **1.144** | **1.093** | **0.649** | **0.840** |
| **4** | **1.100** | **1.111** | **1.105** | **0.935** | **0.691** |

Each cell is the **median of 63 paired runs** (3 sessions × 7 measured sweeps × 3 ingress settings). Candidate wins at 4 workers: **19/63, 10/63, 10/63, 45/63 and 60/63**, respectively. The **128-iteration anomaly at 1 worker (0.561×)** and heavy-work wins must be investigated with stable-frequency repeated measurements and optimized assembly/lock-path profiling: they are **not proven to arise solely from removing mutex acquisition**, especially since one worker has no other worker competing for completion.

### Ingress sensitivity

Across all kernels/workers: median R **0.945×** (ingress 8), **0.913×** (64), **0.910×** (256). Their moderate overall differences conceal the 2/4-worker short-task regressions.

The **original M0** four-worker/two-worker wave-time ratios, based on **63 same-session/sweep/ingress pairs** per intensity, are **1.626 / 1.553 / 1.401 / 1.103 / 0.875** for 0/8/32/128/512 iterations. The **seq-cst candidate's own** 4w/2w ratios are **1.513 / 1.538 / 1.475 / 1.539 / 0.720**, respectively. **Neither variant solves the tiny-task four-worker slowdown**. The candidate is strongly worse in relative 4w/2w scaling at 128 iterations because its 2-worker absolute execution improves much more than its 4-worker execution. These ratios describe relative worker scalability **within each implementation**, not absolute candidate-versus-original performance.

## Parking/backpressure observations (not causal timings)

The benchmark records **counts** of producer `full` retries and worker Condition `parkCount`, not how long retries or waits cost. The revised completion timing/interleaving correlates with **more worker park entries**, particularly for tiny tasks:

| Workers × intensity, all ingresses | Median original parks | Median candidate parks | Median original retries | Median candidate retries |
|---|---:|---:|---:|---:|
| 2 workers, 0 iterations | 35 | **157** | 118 | **40** |
| 4 workers, 0 iterations | 169 | **317** | 32 | **15** |
| 4 workers, 32 iterations | 122 | **294** | 48 | **23** |
| 4 workers, 128 iterations | 46 | **188** | 108 | **29** |
| 4 workers, 512 iterations | 17 | **9** | 1,237 | 1,402 |

These are **independently calculated per-arm medians**, which do not necessarily describe the same sample and cannot be subtracted as paired per-case medians. **More park entries are not proof of more total blocked time**; less producer backpressure can merely accompany earlier worker idleness. Nevertheless, the original and candidate execution dynamics differ substantially despite exact matching task results. Retrying/parking is **not unchanged scheduler behavior at the event-count level** even though the observable admission/completion obligations are preserved.

## Serious thermal qualification limitation

All **six** saved sensor snapshots (before and after each of the three sessions) report **`coretemp Package id 0: +100.0°C (high=+100.0°C, crit=+100.0°C)`** on the i7-9750H, with cooling fans near their reported upper rotation limits. The original manifest also contains an instantaneous CPU scaling percentage, **not a time-series frequency trace**. This is a **thermal-headroom red flag** at the stated high-temperature threshold.

No continuous clock/temperature/thermal-throttling counters, CPU-fan power trace or per-thread pinning were recorded. **Do not claim proven sustained throttling**, but also do **not qualify these numbers as thermally stable optimized-release performance** or generalize small median differences across hardware. The three sessions are not independent machines. A repeat with cooling/thermal headroom and actual frequency observations should be required before any promotion decision. Do not assume the thermal effect biases one particular variant in a fixed direction: process order was alternated by session, not independently randomized within every configuration.

## Decision and proposed bounded follow-up

**KEEP:** both source-pinned P16.2 implementations, successful DMD/LDC/release and close/last-completion/producer races from CI, complete XPS matched-work comparisons and raw artifact hash, alongside the published **sanitized** configuration statistics only. All real TaskRef results, shutdown join/borrow retention and raw event oracle checks pass.

**NO-GO on blanket promotion:**
- Replacing production `completeOne` with seq-cst atomics solely based on the aggregate **0.926×** ratio: with 2 or 4 workers at 0/8/32 iterations the candidate is commonly **5–17% slower** (per worker-intensity medians), and worker parking behavior shifts.
- Claiming that 2/4-worker task-granularity scaling has been fixed; the original shared-scheduler tiny-task problem remains.
- Weakening seq-cst memory orders or removing final Condition notifications in pursuit of performance without a **new** no-lost-final-wakeup / admission-close proof.
- Making a generic public `@safe TaskScope` available, trusting native join/start failure recovery, or claiming C++/Rust parity.

**Next bounded research questions** (NOT completed in P16.2): (1) repeat both uninstrumented builds on thermally stable XPS with monitored per-run CPU clocks/thermal status; (2) check optimized LDC emitted code and source differences, especially striking **1-worker/128-iteration** speedup; (3) isolate why 2/4-worker short-task jobs show **more parks** after removing the completion lock; (4) assess whether **completion batching, less costly lock/atomic ordering or workload-adaptive policy** can retain all admission/close/wake/Thread.join guarantees. One variable at a time, with a genuine baseline and negative/adversarial tests.

**Governance:** ADR-0001 remains **PROPOSED**, [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17) **OPEN**, [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38) **DRAFT**. Do not modify `source/`, `develop`, or grandfathered R0.5 PR #35; P16.2 is an explicitly unpromoted research result.
