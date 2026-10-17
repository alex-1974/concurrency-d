# P18 — complete Dell-XPS native A/B, observational thermal record (2026-10-14)

**Status:** complete matched-work research evidence, **not a production performance qualification**. Retain original P18 M0-vs-grace source and lifetime contracts. No source code, algorithm or scheduler changes are implied.

## Provenance and integrity

- Raw input archive: `p18-xps-20261014-084937-hot.tar.gz`; SHA-256 `86c6426325caa5c7103608a0a67ebcbb0064b872e2fb7881722a397954a0bfa2`.
- Recorded commit `fe6eccb7553b857b44e7fa7114e85d930344f339`; source-pinned **unchanged original M0** blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- Dell XPS 15 / Intel Core i7-9750H; CPU process affinity `0,1,2,3` (four distinct physical cores, worker threads **not pinned individually**); Linux 6.17.0-22-generic; LDC 1.41.0 / LLVM 19.1.7; DUB 1.40.0; release profile.
- Historical runner environment: `P18_ALLOW_HOT=1`, which bypassed the old ≥95 °C preflight; **this provenance is unchanged by the subsequent P18 observability-first protocol revision**.
- Eight independent process raw logs match their extracted CSV rows exactly. Four complete sessions, each with M0 and grace; alternating whole-process order (control→grace, grace→control). Every file has 45 configurations × (2 warm-ups + 5 measured) = 315 rows: **2,520 total rows, 720 warm-ups and 1,800 measured**.
- **900/900 matched measured pairs** pass exact session/round/order/seed/workload/checksum matching, and all timing fields sum exactly to their recorded total. Each case uses 2,048 Tasks × 3 waves; workers 1/2/4, iterations 0/8/32/128/512, ingress 8/64/256. Reference and candidate race fixtures passed 324 cases each in the native run.

## Performance (un-instrumented `waves_ns`; all synthetic cells equally weighted)

`R = grace.waves_ns / original.waves_ns`; `R < 1` favors P18.

| Workers | 0 iterations | 8 | 32 | 128 | 512 |
|---:|---:|---:|---:|---:|---:|
| 1 | 0.9356 | 0.9182 | 0.9436 | 0.9321 | **1.0271** |
| 2 | 0.8848 | 0.8762 | 0.8949 | 0.9518 | **1.0239** |
| 4 | 0.8102 | 0.8075 | 0.8570 | 0.9504 | 0.9827 |

- Overall paired median **0.935882**; P18 wins **675/900** individual comparisons and **38/45** per-configuration medians. It is not an application-weighted performance average.
- Session medians: **0.90118 / 0.94703 / 0.94130 / 0.94729**, favoring grace in both process orders.
- Paired median across ingress capacities: **8 → 0.76538**, **64 → 0.96406**, **256 → 0.96472**. Largest repeatable wins cluster around small burst/backpressure sizes.
- At 512 iterations, the 1- and 2-worker aggregate medians are >1; do not promote as universally superior. Reduced parks are *correlated*, not independently proved as the cause of the elapsed-time changes.
- `waves_ns` excludes construction, pool startup, join and verification. Do **not** extrapolate to complete consumer task submission latency or power/idle efficiency.

## Thermal/frequency evidence and limitations

Original process traces: **8/8** had sampled package temperatures **72–83 °C**, with **zero observed change** in readable package-throttle counters. Process frequencies sampled across CPUs ranged roughly **800 MHz–4.39 GHz** (one low sampled value is not evidence of workload-time throttling). Telemetry had only **3–5 samples per process**, at nominal 500-ms intervals. Absence of sampled throttling does **not** prove none occurred between samples; `scaling_cur_freq` is not measured per-worker instantaneous operating frequency.

**No automatic thermal NO-GO follows from the label `P18_ALLOW_HOT=1`.** That legacy switch was a preflight admission override, not observed evidence that the measured CPU was actually overheating. Equally, no automated thermal **PASS** or production claim follows from the benign sample ranges. Retain both individual arm traces, process-order information and frequency variations for the performance decision.

## Decision and next qualification gate

**KEEP the single-bounded-retry strategy as a research candidate; DEFER production promotion.** A much stronger full A/B dataset now reproduces the short-burst improvement on this host, but the long-task regression signal, worker-power/idle cost, alternative realistic workload mix, and frequency/noise sensitivity still need focused qualification.

Subsequent P18-only protocol revision changes thermal handling from a mandatory ≥95 °C initial gate to **default observation with attention flags**. Optional strict admission remains available for controlled environments. Neither protocol change retroactively alters this input archive nor relaxes correctness/lifetime, DMD/LDC or end-to-end performance gates. Historical P17 data and thermal reviewer remain unchanged. No P19, production `source/`, `develop`, PR #35, or public `@safe TaskScope` change is justified.
