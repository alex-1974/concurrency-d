# P18 — complete Dell-XPS native producer success-Yield cadence study (2026-10-15)

**Result:** Original archive independently VERIFIED: **144/144 whole-release processes, 2,160/2,160 exact-work measured M0/P18 pairs and 864/864 warmup pairs**. Optional producer Yield cadence profoundly changes **original M0's one-core Condition.wait invocation count**, including when producer-full retries are structurally absent. **Important admission limit: severe observed package temperature/throttling prevents quantitative thermal qualification of cadence8/cadence64 one-core speed ratios.** Preserve this as research; no production promotion.

## Original native archive / exact provenance

- User-supplied `p18-producer-cadence-20261015-090020.tar.gz`, **SHA-256 `503c51d4b1220b9acf8c084d34dc746cbcfc4d3567c617b62886884ec5ff7f0e`**. Original host-containing raw archive remains outside public Git.
- Source `ab97b40b249970be26138e997fd4cb3c3ee54d2b`; unchanged original M0 `submission_pool.d` Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, exact original P13 TaskRef/driver/race source-hash pins enforced by the generator. No edited production scheduler or public lifetime contract.
- LDC **1.41.0 / LLVM 19.1.7**, DMD frontend 2.111.0, DUB 1.40.0, Dell XPS i7-9750H, Linux 6.17.0-22. Each of the **six distinct** original M0/P18 × producer-cadence whole-release binaries was built once before runs, retained with SHA-256. Process CPU masks: **one logical CPU {0}**, **four distinct physical cores {0,1,2,3}**; no per-thread pinning. Original runner asserts effective affinity and different core IDs; raw sysfs topology snapshots were not archived.
- The **intentional producer workload intervention** adds a voluntary `Thread.yield()` every 8 or 64 **successful** admissions, skipping the wave-final admission; compiled-out cadence0 has no extra success Yield. Over three waves of 2048 TaskRefs, deterministic additional producer Yields: **0 / 765 / 93**. Existing full-inbox retry Yield, completion polling, unchanged worker algorithm, TaskRef computation, queue/Condition behavior, close/join remain the same. These are **different producer workloads**, so cross-cadence raw elapsed times are not interchangeable scheduler throughput evidence. No guarantee that the recompiled cadence0 binary is byte-identical to the historical unmodified benchmark.

## Independent validation (separate from archived validator output)

- Safe TAR structure: **465 entries / 460 files**, unique names, no unsafe paths, links or unusual member types. All **144 raw logs reconstruct exactly 144 normalized CSVs**, and all 144 have separate telemetry traces. 6 sessions × 2 CPU masks × 3 producer cadences × 4 alternating ABBA/BAAB arm processes.
- **6048 complete scenario rows** (4320 measured + 1728 warmups): 6 seeded/shuffled cells per round × 2 warmups + 5 measured rounds for every process. **2160/2160 paired measured** and **864/864 paired warmup** M0/P18 rows. Complete cross-mask/cadence/arm exact same seed/shuffle/TaskRef checksum. Checksums: 128 iterations `13265944963623`, 512 `13257374174144`, 1024 `13299708084730`.
- Six unique producer-pattern orders, masks and arm order alternation verified from independent session records. Every record passes full stage-time conservation; one worker, 2048 TaskRefs/wave, three waves; expected cadence-Yield count 0/765/93; zero `full` producer retries in **every** ingress2048 case. All six binaries have distinct recorded SHA-256. Original native race/close/producer preflight logs from **M0 and P18 under both masks (4 logs)** explicitly report `PASS scenarios=324` each.
- The 36 `(CPU,cadence,iterations,ingress)` cells each have **60 paired measured ratios**. These are repeated trials on **one XPS host**, not sixty independent machines. No fixed CI speed thresholds.

## Predeclared 512-iteration outcomes

The ratios below are **median of individually matched** `P18.waves_ns / M0.waves_ns` inside one SAME producer cadence and CPU mask, not division of independently aggregated arm medians. `park_count` counts **calls to** `Condition.wait`, not measured sleep or wakeup duration.

| CPU mask | Success Yield cadence | Ingress | Paired P18/M0 | M0 Wait calls | P18 Wait calls | M0 full retries | P18 full retries |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0 | 8 | **0.130166** | **5920** | 0 | 32 | 765 |
| 1 | 8 | 8 | **0.124703** | **5973.5** | 0 | 0 | 0 |
| 1 | 64 | 8 | **0.123721** | **5925.5** | 0 | 30 | 672 |
| 1 | 0 | 2048 | 0.943346 | 34 | 0 | 0 | 0 |
| 1 | 8 | 2048 | **0.124275** | **5977** | 1 | **0** | **0** |
| 1 | 64 | 2048 | **0.114988** | **4654.5** | 0.5 | **0** | **0** |
| 4 | 0 | 8 | 1.031770 | 3 | 0 | 6178.5 | 5956.5 |
| 4 | 8 | 8 | 1.000630 | 3 | 0 | 5424.5 | 5353 |
| 4 | 64 | 8 | 0.986560 | 3 | 0 | 6086 | 6039.5 |
| 4 | 0 | 2048 | 0.995450 | 3 | 0 | 0 | 0 |
| 4 | 8 | 2048 | 0.997260 | 3 | 0 | 0 | 0 |
| 4 | 64 | 2048 | 1.000190 | 3 | 0 | 0 | 0 |

**Strong new qualitative finding:** At **one CPU, ingress 2048**, producer-full retries stay **zero for all three cadences**, yet changing the successful-admission Yield cadence correlates with original-M0 `Condition.wait` invocations **34 → 5977 (cadence8)** or **4654.5 (cadence64)**. Thus full-inbox retry is *not necessary* for M0's repeated wait path. With four CPU cores M0 stays near three waits regardless of cadence, and P18 near zero. With one core/ingress8, M0 Wait counts remain near 6000 across all cadences. This supports a **producer-admission-cadence × CPU-availability × Worker-Parking** interaction in this narrow workload.

In all six sessions at **one CPU/512/ingress2048/cadence8**, the M0 Wait-call medians are **5951, 5994, 5983.5, 5985, 5977, 5946** and paired P18/M0 ratio medians **0.1117, 0.1280, 0.1268, 0.1266, 0.1254, 0.1148**. The qualitative high-wait mode repeats despite order reversals. With four cores/512/ingress8, cadence0 paired ratios by session are **1.0452/1.0108/1.0579/1.0060/1.0149/1.0515**, but cadence8 **0.9943/1.0380/1.0274/0.9773/0.9750/0.9974** (mixed); cadence64 **0.9949/0.9782/0.9991/0.9963/0.9831/0.9790** (small differences). These are *within-cadence* A/B observations; **do not claim cross-cadence scheduler optimization or eliminate historical 512 multicore cost**.

The same one-core/ingress2048 change exists for **128 iterations** (P18/M0 0.4859 / 0.0654 / 0.0411 for cadence0/8/64), and **1024 iterations** (0.8562 / 0.1938 / 0.1985). All three task sizes with ingress8 show strong one-core P18 advantage and four-core near parity. The current uninstrumented cadence collection records **no batch-claim counter**; the previous independent PI experiment recorded M0 small-batch fragmentation, but do **not** claim fresh directly measured batch sizes for cadence8 or cadence64.

## Thermal and environmental disqualification (MATERIAL)

- **277** sparse sysfs samples across 144 processes; **127** traces flagged for attention/missing coverage; measured package temperatures **76–100 °C**. Four-core process maxima at most **94 °C**; most hot observations are on the one-core cadence8/cadence64 arms.
- **28/144 processes** have sampled temperature **≥95 °C**, and **15 processes** have a **positive measured increase in the package CPU throttling counter** (maximum observed increment **+86**). Missing counters and one-sample processes cannot exclude thermal throttling.
- Exactly **55 of 60** matched one-core/512/cadence8 process pairs (both ingress8 and ingress2048) have a ≥95 °C sample in at least one arm. Dropping them leaves just **5 pairs** for that cell: not an adequately qualified cool comparison. Entirely thermally qualified cadence8 one-core speed **cannot be claimed**.
- For one-core/512/cadence64/ingress2048, dropping high-temperature pairs leaves **30 of 60**, with the P18/M0 median **0.1180** vs original **0.1150**; nevertheless no stable per-thread frequency, complete temperature trace, energy or clock-environment qualification.
- For one-core/512/cadence0/ingress8, dropping high-temp pairs retains **50 of 60** and P18/M0 median **0.13017** (unchanged from all 60). This does not transfer clean-room qualification to the other cadences.
- This trial **must not be used to promote a numeric eightfold producer-cadence speed claim or a measured intrinsic yield/Condition cost**. Even without flagged samples, the cadence intervention changes the producer workload itself, CPU running order and turbo/thermal potential.

## Decision and next bounded gate

**PASS archive/completeness/TaskRef correctness and observed producer cadence impact on Wait-call COUNTS; FAIL thermal admission for precise one-core cadence8/cadence64 speed qualification; CPU-specific causal time mechanism still INCONCLUSIVE.** `Condition.wait` count is not blocking latency, and the observed counts do not prove when the worker was runnable or preempted.

Do **not** change production retry/Yield policy, introduce a CPU-count-driven scheduler, remove Condition semantics, create unlimited spin or promise energy/fairness. New numeric speed qualification would need **new low-temperature, source-pinned native ABBA** and a carefully defined unchanged producer workload, preferably with more than one producer/worker and a separate host. Existing original uninstrumented affinity corpus remains independently preserved (SHA-256 `5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`).

**KEEP narrow P18 research / DEFER universal production.** ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT, original M0 production `source/`, `develop`, main, grandfathered R0.5 PR #35 and all prior raw research evidence unchanged.
