# P18 — One-core versus four-core batch/Condition.wait event-only study (2026-10-15)

**Status: SOURCE-PINNED STUDY PREPARED; no native event-only XPS archive collected. KEEP narrow P18 research / DEFER production.**

## Prior native evidence and remaining uncertainty

The complete independent [uninstrumented 1/2/4-physical-core affinity study](xps-2026-10-14-cpu-affinity-review.md) (archive SHA-256 `5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`, original source `1a8b0eab`) establishes an exceptionally large **one-core** P18 advantage for a specific one-worker P13 task workload. At 512 iterations, ingress 8, paired P18/M0 `waves_ns` medians were **0.121511 for one CPU, 1.044167 for two CPUs, 1.036506 for four CPUs** across six balanced sessions. One-core M0 recorded median **5,899** `Condition.wait` entries versus P18 **0**; with two/four cores M0 typically recorded **three** and P18 zero. One-core M0 task admission was often less backpressured in *number of rejected submits* than P18, despite drastically slower measured completion. Raw retry count is not a sufficient time explanation.

The original `TaskInbox.parkUnlessChanged` maintains a generation-gated predicate under its existing mutex; its `_parkCount` increments **immediately before invoking `Condition.wait()`**. This is **not** a measurement of blocking duration, wakeup latency, runnable delay or context-switch count. The one-core correlation could reflect **batch fragmentation, repeated empty/park cycles or the producer/worker interleaving**. A source-level mechanism has not yet been established. At 512/ingress8, M0's 5,899 waiting invocations for 6,144 total TaskRefs suggest a possibility of many very small batch claims, but **the prior uninstrumented archive contains no batch-claim counts**. Do not assert this unmeasured possibility as fact.

## Bounded experiment; no new scheduler instrumentation design

Reuse the already independently qualified **PI event-only** source-pinned M0/P18 research generators, DUB modes `pi-control` / `pi-grace`, original P13 TaskRef kernel/driver and exact one-bounded-idle-retry P18 candidate. Do not add counters, time-stamps, task-source changes, producer-yield changes or production code.

The [native XPS event-only runner](../../../../tools/research/m1_p18_pi_affinity_xps.sh) compares the *same two prebuilt LDC release PI binaries* under **Linux process masks `cpu1={0}` and `cpu4={0,1,2,3}`**, first enforcing distinct physical-core IDs and exact effective process CPU masks. Four sessions alternate **M0/P18** vs **P18/M0** and reverse the order of the two CPU masks, yielding **16 whole event-instrumented processes**. Each process repeats the 12-case `singleingress` matrix: one worker, 2,048 TaskRefs per wave × 3 waves, iterations 128/512/1024, ingress 8/64/256/2048; two warm-ups + five measured rounds.

Expected independent evidence cardinalities: **480 exact-work matched measured event pairs**, **192 warm-up pairs**. Every pair must have identical seed/phase/order/work/task checksum and exact event conservation, subject to the [new cross-affinity event audit](../../../../tools/research/m1_p18_pi_affinity_compare.py) invoking the pre-existing strict [PI event oracle](../../../../tools/research/m1_p18_pi_compare.py). Both arms undergo original **native close/producer-race preflights under one and four CPUs**, with log output retained for review. Source/version/compiler/binary SHA-256, raw stdout, normalized CSV, host/affinity and symmetric thermal telemetry are preserved in a checksum archive outside Git. A deliberately corrupted `Condition.wait` counter in a synthetic CSV must be rejected by the test gate.

## Predeclared primary event questions

For **512 iterations, ingress 8/64/256/2048, one vs four physical CPUs**, compare separately:

1. **Successful inbox batch claims** and total Tasks taken (must equal 6,144). *Derived mean Tasks/batch* = 6,144 / claims when claims >0; report per-arm paired distribution, not only aggregate medians. A large claim count with few Tasks per claim would support the *batch-fragmentation* hypothesis.
2. `park_waits` = original `Condition.wait` entries; `park_no_outstanding` and `park_with_outstanding` use the same inbox mutex to classify the **accepted-minus-completed state immediately before waiting**. They conserve exactly to `park_waits`. This is an obligation snapshot, **not a proof of kernel sleep/wakeup outcome**. Count repeated parks with/without outstanding obligations; also compare `park_attempts` (which can return without a wait).
3. `takeCalls`, `takeEmpty`, `wakeReads`, `drainReads`, `announceCalls`: counts of existing mutex-associated ingress/parking state checks. These are **not durations or contention samples**.
4. Producer `submitFull == retries`, `pollYields`, maximum occupancy and occupancy histograms, **including 2048-capacity cases where producer full retries must be zero**. A shift between admission and completion-polling remains relevant even if total yield invocations stay similar.
5. P18 `grace_searches` and its conserved classification into local/inbox/steal recovery, fallback and drained-exit. Under one worker there must be **zero foreign-steal attempts/recoveries**. Do not infer fairness or global scheduler behavior from this one-worker workload.

**Critical instrumentation contingency:** the event-only PI variant adds counters *inside the existing inbox mutex* and per-worker event counters. This perturbs the producer/worker race and scheduling. The dramatic one-core M0 wait pattern may fail to reproduce; if so, classify **INCONCLUSIVE**, rather than explaining uninstrumented wall time by unrelated traced event counts. Even when event counts agree in direction, `Condition.wait` invocation count or batch mean does **not** measure lost CPU time or prove the cause of the observed speedup.

## Native execution

In a fresh detached exact-research-commit worktree, after DMD/LDC CI passes:

```bash
P18_PARK_SESSIONS=4 \
  bash tools/research/m1_p18_pi_affinity_xps.sh ldc2 \
  /tmp/p18-onecore-parking-events-YYYYMMDD
```

Check exact source pin and original M0 Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`; no `sudo`, kernel/security setting changes, `perf` or `/proc` observer. Do **not** interpret instrumented `waves_ns` or `total_ns` as new performance evidence. The separate **uninstrumented 2,160-pair native CPU-affinity corpus** remains the only speed reference for this intervention. Do not publish raw host-bearing archive without review; preserve partial evidence instead of fabricating missing pairs.

If this event-only probe motivates a candidate, test its **correctness/lifetime/close/producer/race** properties and both **one-core and multi-core uninstrumented LDC performance** separately before considering production; no adaptive policy, indefinite spin or general public `@safe TaskScope` is qualified.

**ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT, grandfathered R0.5 PR #35, production M0 `source/`, `develop` and other repositories unchanged.**
