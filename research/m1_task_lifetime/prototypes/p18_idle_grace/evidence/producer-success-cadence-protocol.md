# P18 — Source-pinned producer admission-cadence intervention (2026-10-15)

**Status: bounded research experiment prepared; no native producer-cadence XPS result yet.** This is an **intentional change to the producer workload**, NOT a change to the M0 or P18 worker scheduler, queue, TaskRef execution or release API.

## Motivation and independent preceding evidence

The independently audited native [one/four-core producer/worker batch-event study](xps-2026-10-15-onecore-parking-batch-events-review.md), original archive SHA-256 `74e69fb3fd4f2cf84244b07185afdc57ab2a7fbcf96197518c65caadfd1abeea`, replicated dramatic one-core M0 batch fragmentation with ingress 8: **5,920 successful inbox batch claims of 6,144 Tasks, 1.04 Tasks/claim, and 5,920 real `Condition.wait` call entries**. P18 under the same one-core event-only study claimed **768 full 8-Task batches, 8.0 Tasks/claim and zero median waits**, with 767 Grace inbox recoveries. Four-core M0 and P18 both claimed 768 full-size batches; M0 waited three times. At ingress=2048, original M0 one-core still showed ~147.5 wait calls despite zero rejected-full producer submits. All waits in the event-only archive were observed with accepted==completed immediately before the Condition invocation; this is not a time or CPU-sleep measurement.

Only the *separately uninstrumented* native one/two/four-core ABBA corpus, SHA-256 `5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`, supports performance: at 512 iterations/ingress8 the median P18/M0 `waves_ns` ratio was **0.121511 (one CPU)**, **1.044167 (two)** and **1.036506 (four)**. None of these measurements established a causal per-wait cost or whether producer admission cadence makes batches smaller.

**Testable question:** does the *rate at which the producer voluntarily yields AFTER successful admissions* control the original one-core M0 batch-fragmentation/parking pattern, or can the same effect occur without that producer intervention? This is not a simulation of external producers, and a single-thread producer is still a narrow consumer.

## Experimental factor and exact source pin

The [source-locked research generator](../../../../tools/research/m1_p18_cadence_make_fixture.py) first invokes the *unchanged* established P18 source-hash-pinned P13 generator, which checks:

- original production M0 pool Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a` through the existing P18 pool generator;
- P13 TaskRef task kernel `3852e8788757b62c5000ad55565359d6a20a78c1`;
- P13 consumer driver `723de6bf76ac838b10de4b3f1cb901315a5ced38`;
- P16.2 native race fixture `f158e14ef7a69cff1d2a5005090926794a5846ce`.

It then creates a **new uniquely named generated research kernel/consumer** with a compile-time-only constant `P18ProducerCadence` and one strictly delimited producer change. When a `trySubmit` succeeds, and **not after the final TaskRef in a wave**, the producer optionally calls `Thread.yield()` after each N-th successful admission. Original `SubmissionResult.full` retries (including the original retry Yield), all completion polling, TaskRef record identity/execute/post-dispatch mark, native close/join and grace search behavior remain byte-for-byte sourced from the originals. There is no mutex added, hot-path counter, timestamp or kernel tracepoint.

| New compile-time workload | Additional voluntary producer Yield cadence | Deterministic extra yields over 3 × 2048 TaskRefs |
|---|---|---:|
| `cadence0` | None (compiled-out additional success-yield branch) | **0** |
| `cadence8` | After every 8 accepted Tasks except wave final | **765** |
| `cadence64` | After every 64 accepted Tasks except wave final | **93** |

The generated driver writes a separate `cadence_yields` CSV column **computed outside the hot loop from stride/count/waves**. It is a deterministic expected-workload count, **not independently measured kernel Yield calls**. It gives a fail-closed manifest/validator check. The generated `cadence0` module is **not guaranteed byte-identical** to the historical unmodified release benchmark even though the additional branch is compiled away, and no such binary-identity claim is permitted. No original P13 source or production `source/` file is modified.

The experiment compares *original scheduler M0 vs the existing bounded P18 scheduler* **within each of these three deliberate producer workloads**. A raw ratio between `cadence0` and `cadence8` is **not** a semantically identical work performance optimization claim: producer Yield behavior is itself the manipulated factor. Do not combine or rank cadences as interchangeable production schedulers.

## Native qualification and predeclared matrix

The [new LDC-release XPS runner](../../../../tools/research/m1_p18_cadence_xps.sh) checks 1 vs 4 distinct physical-core CPU masks: `cpu1={0}` and `cpu4={0,1,2,3}`, with verified Linux `taskset` effective mask and unique package/core identifiers. Producer and worker are not individually pinned. It builds **six immutable binaries** (three cadences × original M0 or bounded P18) before collecting measurements; runs native original race/close/producer checks for each arm at both CPU masks and retains those original logs.

The task workload matrix is deliberately smaller than the previous affinity study:

- **One worker;** original P13 TaskRef arithmetic with iterations **128, 512, 1024**; ingress **8 vs 2048**, bounded **2048 TaskRefs/wave × 3 waves**.
- Exactly **six balanced sessions**, all six producer-pattern orders, alternating order of `cpu1`/`cpu4` and of **M0/P18/P18/M0** versus **P18/M0/M0/P18** per session.
- Every whole release process has 2 warmups and 5 measured rounds over 6 seeded/shuffled scenario cells.
- **144 whole processes = 6 sessions × 2 CPU masks × 3 cadences × 4 scheduler-arm occurrences. 2160 directly matched measured pairs and 864 warmup pairs**, with **60 matched measured pairs per cell** (6 sessions × 2 adjacent A/B halves × 5 rounds).
- Compile-time generated source and six release binaries are fixed for the full session set. Preserve SHA-256 binary/source/compiler, stdout, CSV, original race logs, CPU topology checks, observational thermal/frequency telemetry and refusal to overwrite destinations.
- [Independent cadence-matrix validator](../../../../tools/research/m1_p18_cadence_compare.py) checks **all 144 exact process CSVs**, per-round complete six-case matrix, identical fixed TaskRef seed/shuffle/count/waves/checksums across all CPU masks and producer workloads, stage-time conservation, zero `full` retries when ingress is at least a full wave, and exact deterministic 0/765/93 extra success-Yield counts. The negative oracle falsifies one count and requires rejection. DMD/LDC smoke is source pinned; LDC whole-release correctness gates are mandatory. **No CI speed threshold.**

**Note on cardinality:** 60 paired measured M0/P18 comparisons per `(cpu mask, cadence, iterations, ingress)` cell, with six sessions as the experimental host-unit; never treat 60 rounds as 60 independent machines.

## Interpretation; explicit stop rules

Within each *same* cadence/mask/iteration/ingress, report the distribution of paired uninstrumented native P18/M0 `waves_ns` ratios, absolute waves times, producer full retries and M0/P18 park counts. Use the 128/1024 cases to show whether a 512-specific effect remains. Report by **session and adjacent ABBA half**, include telemetry flags and never claim continuous thermal/frequency or energy qualification from sparse temperature sampling.

*Potential observations* (not predictions): If voluntary post-accept Yield alters one-core M0 parks markedly, producer pacing is implicated as a scheduling input, **not** proven as the per-wait latency source; if the one-core batch/park pattern remains stable at all three cadences, cadence of successful admissions appears less central. A strong four-core 512 response may motivate a narrower follow-up to explain the small historical regression. If results change direction by session, classify as INCONCLUSIVE, not promote a policy.

Do **not** automatically configure production Yield by CPU count, add delay after every admission, remove Condition synchronization, busy-spin indefinitely or promise general fairness/energy. The deliberate cadence variation is a research consumer only. Any production candidate must retain or improve TaskRef/lifetime/race and closure semantics and pass **independent uninstrumented native release ABBA on one AND multiple cores**, with more than the single synthetic P13 workload.

**Disposition: KEEP P18 narrowly in research / DEFER general production.** Original M0 `source/`, `develop`, grandfathered R0.5 PR #35, ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT and raw prior native evidence unchanged.
