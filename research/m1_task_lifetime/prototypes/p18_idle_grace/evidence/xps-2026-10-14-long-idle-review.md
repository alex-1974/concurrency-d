# P18 — Dell-XPS long-task and zero-work idle follow-up (2026-10-14)

**Disposition: KEEP narrow research hypothesis / DEFER unconditional production promotion.** This report reviews uploaded native archives; it is not a new scheduler implementation and does not change any API/lifetime claim.

## Primary source/provenance

- Long: `p18-xps-long-20261014-092738.tar.gz`, SHA-256 `13134165acf1014cff5f64daf479fbb4f1d19ad745b90fc0e76dc4bf7b67c21f`.
- Idle: `p18-xps-idle-20261014-092738.tar.gz`, SHA-256 `42332be5efca76291fb8422b597b02154e844f0f445f35a552608fd92d27455f`.
- Both manifests identify **source-locked HEAD `8efb55dd7ae3f843c8e0fa23ca56f9a615b5e234`**, original unchanged-M0 `submission_pool.d` blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, LDC 1.41.0 / LLVM 19.1.7, whole-release on Dell XPS 15 i7-9750H, process affinity four physical cores `0,1,2,3`. Workers **not** individually pinned. P18 is **one bounded yield plus one additional search**, NOT the P16.2 atomic candidate.
- Four complete independent A/B sessions in **both** archives; sessions 1/3 order M0→P18, sessions 2/4 P18→M0. Original raw stdout CSV lines were checked against all normalized CSV files with exact text equality. No unsafe tar member paths/links.
- Original raw archives are retained **outside Git** because manifest/logs contain host information. This summary and the archive checksums do not replace raw evidence.

## Exact workload/oracle validation

**Long-task:** 4 sessions × 2 arms × 45 settings × (2 warmups + 5 measured) = **2,520 total rows**, 720 warmups and 1,800 measured. **900/900 measured matched pairs** agree exactly on phase, round, order, seed, workers, 2,048 tasks/wave, 3 waves, iterations, ingress and checksum. Each process includes all 45 settings (workers 1/2/4 × iterations 128/256/512/1024/2048 × ingress 8/64/256). All stage times are nonnegative and sum exactly to `total_ns`; retries/parks nonnegative. P13 kernel validates accepted/completed counts, returned flags and oracle and joins native workers.

**Idle:** 4 sessions × 2 arms × 3 worker counts × 3 settled one-second windows = **72 measurements / 36 matched windows**, with 250 ms settling and 1,000 ms holds. Exactly **zero admitted/completed TaskRefs**, and all native workers join. All 72 records show `parks_before == parks_after == workers` (1/2/4), so the workers have already parked and never park again during settled no-work windows.

## Long-work release wave latency (P18 / unchanged M0)

Values are **medians of within-workload matched** `waves_ns` ratios, not ratios of global arm medians, and not an application-weighted speedup. A value above 1 means P18 is slower.

| Iterations | 1 worker | 2 workers | 4 workers | Across workers |
|---:|---:|---:|---:|---:|
| 128 | 0.9893 | 0.9802 | 0.9924 | 0.9883 |
| 256 | 1.0398 | 0.9974 | 1.0485 | 1.0201 |
| **512** | **1.0484** | **1.0494** | **1.0269** | **1.0449** |
| 1024 | 0.9981 | 0.9995 | 0.9895 | 0.9971 |
| 2048 | 0.9958 | 1.0203 | 0.9988 | 1.0044 |

Overall 900-pair median = **1.008093**, 407/900 P18 wins, **20/45** case medians favor P18. Sessions (225 pairs each) medians: **0.967610 / 1.024248 / 1.051121 / 1.002658**. Variation is meaningful: session 1 favors P18 while sessions 2–3 regress. Order alternates, so it does not support one-sided ordering as a complete explanation.

At **512 iterations** the paired session medians (columns S1/S2/S3/S4) are:

| Workers | S1 M0→P18 | S2 P18→M0 | S3 M0→P18 | S4 P18→M0 |
|---:|---:|---:|---:|---:|
| 1 | 0.9949 | 1.0578 | 1.1023 | 1.0163 |
| 2 | 1.0096 | 1.0892 | 1.1196 | 1.0333 |
| 4 | 0.9544 | 1.0241 | 1.0802 | 1.0452 |

The 512-work result independently corroborates a **small but real workload-specific regression signal** seen in the prior short-work corpus, including 4 workers in this new corpus. It does **not** prove the idle grace itself is the root cause; producer retries and parks are also changing. At 1024 and 2048 iterations ratios return toward parity: no monotonic increase with task length. A secondary `total_ns` 512-iteration median ratio is **1.0285** (includes setup, join, and verification, not the same timing boundary as `waves_ns`).

## Sustained zero-work process CPU activity

A one-second window measures *process* C `clock()` CPU time divided by monotonic wall time. It includes the test coordinator; it is **not individual worker time or electrical energy**. Medians below are CPU **milliseconds per wall second**, and the paired P18−M0 delta, over 12 windows per worker count:

| Workers | M0 CPU ms/s | P18 CPU ms/s | Median paired Δ CPU ms/s |
|---:|---:|---:|---:|
| 1 | 0.0470 | 0.0210 | −0.021498 |
| 2 | 0.0375 | 0.0165 | −0.004499 |
| 4 | 0.0430 | 0.0250 | +0.000001 |

Individual absolute CPU times are only **12–61 μs per one-second window**; tiny deltas are near measurement/environmental noise and must **not** be promoted as P18 energy savings. **Neither variant exhibits sustained additional parks or a measured persistent busy loop** after its initial settle under *zero admitted work*. This does not measure transient grace effort at burst boundaries or actual system power/C-states.

## Thermal and attribution limits

- Long: eight process traces with nominal 500-ms sysfs sampling; observed package temperatures **73–94 °C**, zero observed package-throttle-count changes. Not isothermal: session 4 medians 83 °C M0 versus 92 °C P18. Sampled `scaling_cur_freq` is not a measured stable per-worker clock.
- Idle: eight process traces, observed **52–89 °C**, zero observed counter changes; session 2 thermal medians 54.5 °C M0 vs 76.5 °C P18 despite tiny process CPU usage. This is **confounded by independent process ordering/system state**, not evidence that P18 creates 22 °C of heat.
- Absence of sampled throttle increments does **not** exclude events between samples. Temperature alone does not decide benchmark validity. Matched-work comparisons are separated in time and the observed session dependence must be retained.

## Next gate and exclusions

**KEEP the bounded retry as short/bursty-work research, DEFER a universal scheduler default**: the earlier short-work corpus favors P18, especially ingress 8, but the new long-work profile is near parity overall with a recurring 512-iteration regression. Idle data do not demonstrate sustained busy-poll overhead or an energy advantage.

If continuing, isolate **512-iteration** behavior with separately instrumented stealing/search/wait and producer behavior, and uninstrumented paired throughput with better control of order and CPU-frequency drift; assess task-size dependence before attempting an adaptive policy. Actual energy claims require instrumentation designed for energy, not process `clock()` ratios.

Production M0 and TaskRef layout, wake-generation/Condition semantics, exceptional Thread.start/join failure caveats, arbitrary `@safe TaskScope` NO-GO, ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT, `develop` and the grandfathered R0.5 PR #35 are unchanged.
