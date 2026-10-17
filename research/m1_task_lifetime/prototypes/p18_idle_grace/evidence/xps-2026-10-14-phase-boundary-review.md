# P18 — Independent native XPS single-worker phase-boundary audit (2026-10-14)

**Disposition: KEEP narrow research / DEFER universal production.** This is a strict independent review of phase-instrumented M0 vs bounded-idle-grace P18. **Do not use instrumented elapsed wave times as a replacement for the existing completely uninstrumented speed evidence.**

## Original source and archive

- Uploaded original `p18-phase-xps-20261014-154309.tar.gz`, **SHA-256 `05a1de88e6c700908e78b3cb1e72f01f370203a6ac421fa22d72cb22476ffc6d`**. Raw host/path-bearing archive retained outside public Git.
- Manifest exact research HEAD **`1c402593be8b1c9756d6fed90f7e02914555099c`**, original unchanged M0 `submission_pool.d` blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, LDC **1.41.0** / LLVM 19.1.7, DUB 1.40.0, Dell XPS 15 i7-9750H. Process affinity CPUs 0–3; worker and producer **not individually pinned**.
- Prebuilt distinct LDC release binaries: phase-control SHA-256 `01aff3fe476084a66908cb3a8cb31c3dfb3f437e7f614aed624bbd89970f0fbe`; phase-grace `1c97751aa7346b47d88dc197a3fabb4e7ca71cea56d6f740c7a772a6ee696368`.
- **4 complete alternating-order ABBA/BAAB sessions; 16 complete whole processes**, 12 settings per process (1 worker × kernel 128/512/1024 iterations × ingress 8/64/256/2048), 2,048 Tasks per wave × 3 waves, 2 warm-ups and 5 measured rounds. **480/480 measured and 192/192 warm-up exact matched pairs**; all original raw log CSV lines byte-equal normalized CSV, scenario/phase/round/order/seed/TaskRef checksum equality, stage + phase conservation, nonnegative intervals and completed-at-last-admission bounds. At 2048 ingress every original and candidate process has **zero producer-full retries**. Native producer/close race preflights are mandatory in runner but stdout not independently retained in archive.

## Measured source-pinned *phase* observations

Each phase-stamped arm records, per wave, startup until first accepted TaskRef, time first-to-last accepted TaskRef, time last accepted TaskRef to completed wave, and unassigned residual. **All four intervals sum exactly to `waves_ns`**. A single acquire snapshot per wave records already-completed Tasks at last admission. Additional timestamps/snapshot may perturb scheduling even when both arms share identical instrumentation.

Below, ratio = median of **matched per-row** `phase-grace.waves_ns / phase-control.waves_ns` ratios; differences are median of **matched per-row** P18 minus M0 intervals, microseconds. Ratios are **instrumented phase-study observations, NOT new scheduler throughput qualifications**. Each cell has 40 measured pairs from 4 host sessions, correlated across rounds.

| Iterations | Ingress | Phase-study ratio* | Paired Δ submission µs | Paired Δ completion wait µs | Completed-at-admission M0/P18 (out of 6144) |
|---:|---:|---:|---:|---:|---:|
| 128 | 8 | 0.9347 | -182.3 | +0.4 | 6118 / 6116 |
| 128 | 64 | 0.9557 | -125.8 | -1.1 | 5941 / 5943 |
| 128 | 256 | 0.9237 | -201.6 | -4.5 | 5367 / 5366 |
| 128 | 2048 | 0.9558 | -52.3 | -4.6 | 931 / 824 |
| **512** | **8** | **1.0403** | **+221.3** | **-0.5** | **6096 / 6097** |
| **512** | **64** | **1.0458** | **+258.2** | **-1.3** | **5928 / 5929** |
| **512** | **256** | **1.0435** | **+250.2** | **-2.5** | **5352 / 5352.5** |
| **512** | **2048** | **0.9951** | **-27.6** | **+13.6** | **172 / 158** |
| 1024 | 8 | 0.9892 | -98.4 | +0.5 | 6096 / 6096 |
| 1024 | 64 | 0.9849 | -137.2 | -1.1 | 5928 / 5928 |
| 1024 | 256 | 0.9851 | -132.4 | -8.6 | 5352 / 5352 |
| 1024 | 2048 | 1.0021 | +2.0 | +35.9 | 69.5 / 68 |

**Localization at 512:** under tight ingress the added P18 interval cost occurs overwhelmingly **between first and last accepted TaskRef**, not after last admission. M0/P18 median submission spans (milliseconds): ingress 8 **5.296/5.503**, 64 **5.175/5.445**, 256 **4.638/4.886**, 2048 **0.346/0.336**. Corresponding post-submission completion waits: 8 **0.037/0.036**, 64 **0.166/0.164**, 256 **0.616/0.618**, 2048 **4.676/4.689**. This localizes a **wall-time interval**, not a CPU instruction cost or mutex waiting duration.

**Overlap:** At the last admission during a 512-iteration measurement, completed Tasks are near-equal between M0 and P18 within each ingress setting, but change dramatically with capacity: ~**99.2%** already completed at 8, **96.5%** at 64, **87.1%** at 256, and **2.8% M0 / 2.6% P18** at 2048. Thus tight producer backpressure forces much task progress to coincide with admission; a full-wave-capacity inbox shifts execution into the completion-wait interval. This describes scheduling overlap; it does not prove why P18 takes longer in the admission interval.

## Sessions and thermal

| Session | 512/8 phase ratio* | 512/64 | 512/256 | 512/2048 |
|---:|---:|---:|---:|---:|
| 1 | 1.0427 | 1.0646 | 1.0825 | 0.9942 |
| 2 | 1.0535 | 1.0419 | 1.0382 | 1.0019 |
| 3 | 1.0096 | 1.0262 | 1.0296 | 0.9992 |
| 4 | 1.0129 | 1.0034 | 0.9936 | 0.9904 |

**512/8 and 512/64** phase ratios exceed unity in all four sessions, while **512/256** reverses in session 4; the no-full 2048 case is near parity. Geometric collapsing of adjacent ABBA halves first yields 512 medians **1.0336/1.0435/1.0512/0.9904**. Paired cases are correlated inside four host sessions: do not claim formal independent-sample significance.

Thermal: all **16** process telemetry traces contain only **2 package temperature readings each** (observed **78–90°C**, **zero observed throttle-counter increments**). One or more sampled sysfs frequency values fall to **800 MHz**, so sampled reported frequencies do **not** establish stable per-worker execution clocks; no watt/joule measurement. These observations neither prove isothermal performance nor invalidate all matched comparisons automatically.

## Separate historical uninstrumented throughput evidence

The fully uninstrumented native one-worker ABBA archive (SHA-256 **`a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`**) remains the proper speed reference. Its 512-iteration median P18/M0 `waves_ns` ratios at ingress 8/64/256/2048 were **1.0627/1.0392/1.0539/0.9875**. The new phase-instrumented ratio directions largely agree but **must not be numerically pooled** or treated as interchangeable. No new scheduler semantics were tested.

## Bounded next gate and preserved status

**KEEP P18 for narrow research; DEFER unconditional production.** The evidence identifies **the producer admission interval under backpressure** as the principal interval of the 512-work phase divergence, not its microarchitectural cause. It does **not** prove `Thread.yield()` cost, mutex contention duration, producer/worker CPU migration, power/fairness effects, or recommend a 2048-slot default.

If continuing, collect external producer/worker scheduling data (thread run/blocked/migrations) synchronized with coarse phase boundaries under pinned source, or investigate a tightly bounded producer-side retry policy. Any change needs a **fresh independent uninstrumented** original-M0/P18/candidate release A/B qualification with native race/close/join oracle and symmetric thermal provenance before adoption.

Production `source/`, `develop`, grandfathered R0.5 PR #35, ADR-0001 **PROPOSED**, Issue #17 OPEN, PR #38 **DRAFT**, and public `@safe TaskScope` NO-GO remain unchanged.
