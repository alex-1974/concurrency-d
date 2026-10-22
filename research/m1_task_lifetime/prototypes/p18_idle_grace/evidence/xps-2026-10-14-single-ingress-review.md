# P18 — native single-worker ingress/backpressure ABBA audit (2026-10-14)

**Disposition: KEEP narrow research / DEFER universal production.** This is an independent analysis of the complete native XPS *uninstrumented* single-worker A/B/B/A corpus, not a new scheduler implementation.

## Source, archive and strict work matching

- Original `p18-single-ingress-20261014-124632.tar.gz`; SHA-256 **`a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`**. Keep the raw archive outside public Git because original manifest/logs may include host information.
- Source-pinned research HEAD **`e91c4eb967df85274049fc773e01a46148600f7e`**, unchanged original M0 `submission_pool.d` Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, LDC 1.41.0 / LLVM 19.1.7, DUB 1.40.0, Dell XPS 15 i7-9750H, release build. Process affinity `0,1,2,3`, **individual producer/worker threads not pinned**.
- Immutable prebuilt binary SHA-256: control `9a40f2bd3a11331a6603aed7bc5e0cc5d4e04d5906aad3866766696f052de3a7`; P18 `2709689f77439a1dafd7c039101fc41416bb6e78a01c69cc55b5a69d2d8d789e`.
- Four **complete** alternating A/B/B/A and B/A/A/B sessions, 16 independent processes. Each process contains 12 cases × (2 warm-ups + 5 measured) = **84** scenario rows. Exact raw-log/normalized-CSV byte comparison and independent scenario/range/matrix/seed/phase/stage/checksum validation **PASS**. **480/480 measured paired rows** and **192/192 warm-up paired rows** have identical TaskRef workloads and matching result checksums. Native race preflights are mandatory in the runner, but preflight stdout was not independently retained in the archive.
- Exactly **one worker**, 2,048 TaskRefs per wave × 3 waves, iterations **128,512,1024**, ingress **8,64,256,2048**; 40 paired measured ratios per cell.
- **Crucial independent admission check:** All sixteen processes have **zero full-inbox producer retries at ingress 2048**, during warm-ups and measured rounds; the exact 2,048-slot inbox can fit a complete 2,048-TaskRef wave independently of concurrent draining.

## Uninstrumented matched `waves_ns` ratio

`R=P18.waves_ns/original.waves_ns`; **median of each individually matched ratio**, not the ratio of separate medians. `R>1` means P18 is slower.

| Task iterations | Ingress 8 | Ingress 64 | Ingress 256 | Ingress 2048 | Pooled (160 pairs) |
|---:|---:|---:|---:|---:|---:|
| 128 | **0.9280** | **0.9273** | **0.9577** | **0.9567** | **0.9395** |
| **512** | **1.0627** | **1.0392** | **1.0539** | **0.9875** | **1.0377** |
| 1024 | 0.9913 | 1.0027 | 0.9941 | 1.0131 | 1.0004 |

**Core observation:** With **512 iterations**, P18 is 3.9–6.3% slower at ingress 8/64/256, but its median turns ~1.3% favorable with **zero full-inbox retries** at capacity 2048. The difference between M0 and P18 remains visible in `total_ns`, but smaller, and verification time is inside `total_ns`.

At 512, median full-inbox retries M0/P18: ingress 8 **6156.5/5925**, 64 **5948/5736**, 256 **5368.5/5139.5**, 2048 **0/0**. Median actual park events M0/P18 remain **3/0** at all four capacities: counting parks alone does not explain the striking capacity-dependent latency result.

The paired median **`total_ns`** ratios at 512: ingress 8 **1.0267**, ingress 64 **1.0285**, ingress 256 **1.0262**, ingress 2048 **0.9912**. These include pool preparation/join/verification and should not be described as end-to-end consumer performance.

## Session/order sensitivity

| 512 iterations, per-session median | Ingress 8 | Ingress 64 | Ingress 256 | Ingress 2048 |
|---:|---:|---:|---:|---:|
| S1 | 1.0246 | 1.0312 | 1.0655 | 1.0088 |
| S2 | 1.0693 | 1.0410 | 1.0553 | 1.0024 |
| S3 | 1.0555 | 1.0348 | 1.0420 | 0.9671 |
| S4 | 1.0633 | 1.0578 | 1.0502 | 0.9789 |

All four sessions show a 512-iteration median regression at **each of the three smaller capacities**. Ingress 2048 is **near parity** and reverses across sessions: S1/S2 slightly behind, S3/S4 ahead. Thus `0.9875` does **not** prove universal P18 improvement.

Collapse adjacent ABBA halves first via the geometric mean of their matching ratios (n=20 per cell, not 40 separate process pairs): 512 medians ingress 8 **1.0615**, 64 **1.0396**, 256 **1.0483**, 2048 **0.9850**. This preserves the qualitative result.

Only as a **diagnostic relative-to-control comparison**, within the same session/half/round/ingress: `R512/sqrt(R128*R1024)` median is **1.0949 / 1.0819 / 1.0912 / 1.0033** across ingress 8/64/256/2048. The anomalous 512 *relative* response nearly disappears under zero-full admission. It is **not** a permitted normalization replacing measured absolute wave times, nor a causal model.

## Thermal/environment limitations

All sixteen read-only telemetry process traces have **only 2 temperature samples per process**, 78–88°C package observations, and **zero observed package-throttle-counter increments**. Some sampled `scaling_cur_freq` values of 800 MHz are not calibrated instantaneous worker execution clocks; none of these sparse samples proves stable frequencies or absence of transient throttling. The scheduler and producer are not individually affined; concurrent system background load is not controlled. There is no direct power measurement. Four sessions do not constitute forty independent host sessions.

## Research interpretation and next bounded gate

**SUPPORTED hypothesis:** The task-size-specific **512-work regression interacts strongly with bounded ingress capacity/producer backpressure**. Removing `SubmissionResult.full` retries by giving a complete wave 2048 inbox slots largely eliminates the unusual 512 response, without changing the single-worker M0 or P18 algorithm. The source-locked P13 producer always yields on full; at tight ingress, thousands of producer retries dominate the very few P18 worker-yield attempts. This is a correlation under a controlled *capacity* intervention.

**NOT YET PROVEN:** That producer `Thread.yield()` itself causes the regression. Inbox capacity also changes queue occupancy, locking/interleavings, cache locality and producer/worker concurrency; those changes are confounded. A 2048-slot queue is not necessarily the right general default. No causal adaptive policy, fairness claim, power improvement, general GUI suitability or public `@safe TaskScope` follows.

**Next step, if authorized:** Isolate the producer retry/yield behavior and inbox occupancy with independent source-locked diagnostic overlays, and test any proposal again as a **separate uninstrumented whole-release paired native comparison** with matching TaskRefs, native race/close/join tests and thermal/frequency provenance. Retain past failing hypotheses and artifacts.

**Decision unchanged: KEEP P18 narrowly as short-burst research; DEFER unconditional production promotion.** Production `source/`, `develop`, grandfathered R0.5 PR #35, ADR-0001 PROPOSED, Issue #17 OPEN and Draft PR #38 remain unchanged.
