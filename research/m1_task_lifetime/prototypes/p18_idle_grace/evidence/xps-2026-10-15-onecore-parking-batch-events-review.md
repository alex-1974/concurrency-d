# P18 — Native XPS one-core/four-core Condition.wait and batch-event follow-up (2026-10-15)

**Outcome:** Complete independent audit **PASS**. One-core **M0 batch fragmentation** and thousands of Condition.wait *invocations* are reproduced in source-pinned event-only research copies. **This is mechanism evidence, NOT instrumented speed qualification or a measured per-wait cost.** Keep P18 narrowly in research; defer unconditional production.

## Immutable source and artifact provenance

- Original archive `p18-onecore-parking-events-20261015-081542.tar.gz`; SHA-256 **`74e69fb3fd4f2cf84244b07185afdc57ab2a7fbcf96197518c65caadfd1abeea`**.
- Source HEAD **`e4f461ce21dfa9e1fb751e976b2ce33d92908b84`**, original production M0 pool Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, pinned P13 TaskRef kernel/producer and one-bounded-grace P18 unchanged.
- LDC **1.41.0 / LLVM 19.1.7** release, DUB 1.40.0, XPS i7-9750H, Linux 6.17.0-22; process affinity `cpu1={0}` and `cpu4={0,1,2,3}` (no individual thread pinning). Runner reports it verified distinct physical core IDs and exact effective CPU masks; the archive does not contain separate raw sysfs topology snapshots.
- Both event-only release binaries were compiled before events and reused across all cases: PI control SHA-256 `8f5dd2aea9f779afab073c8a144e0cb064d747a9ffc257f340f6b1774f29d39b`, PI grace `c5dfb1017da20c6ec814a4b3982673b8f27e7f4458d837c6335239dbf3d03958`. **These are identical to the previously recorded PI trace binaries; they are not the uninstrumented speed binaries.**
- Full original raw archive remains outside Git; it can contain host-sensitive paths and metadata.

## Independent archive, workload and native correctness audit

- Safe TAR member checks, no path traversal, symlinks or duplicate names: **96 entries / 91 files**.
- Four complete sessions, two masks and two arms: **16/16 whole event-instrumented native processes**; 16 original raw logs byte-identical to the extracted CSV rows; 16 corresponding sysfs temperature/frequency telemetry traces.
- Every process includes **12 scenario cells × (2 warmups + 5 measured rounds) = 84 rows**. **1,344 total valid rows, 480/480 paired measured + 192/192 paired warmup cases**; exact seed, phase, shuffled order, one worker, `count=2048`, three waves, 128/512/1024 iteration count, ingress 8/64/256/2048 and iteration-specific TaskRef checksums identical across arm *and affinity*.
- For **every** row: `submitAccepted = takenTasks = completeCalls = batch_tasks = 6144`; `submitCalls = accepted + full + closed`; `submitFull = retries`; `closed=0`; inbox occupancy bins sum to accepted; `takeCalls − takeEmpty = batch_claims`; `park_count = park_waits = park_no_outstanding + park_with_outstanding`; P18's extra search and every terminal result category conserve; no steals with one worker. Every high-capacity (2048) case has **zero full-inbox rejects**.
- All four *original* native race/close/producer preflight logs retained and report `P16.2 close/complete/park/producer-race PASS scenarios=324` for both arms under one and four cores. These are recorded actual results, unlike earlier archives which only enforced preflight without retaining it.
- Exactly **16 thermal summaries, 49 samples in total** (2–7 per process), observed **71–88 °C**, zero observed package-throttle-counter increments; no sampled observation proves stable thread frequencies, lack of transient throttling or energy use.

## Primary event finding: 512 iterations; each entry median of 20 measured exact-work pairs

Tasks per batch = **median of per-measurement `6144 / batch_claims`**, rather than dividing independent medians. Waits count calls immediately before original `Condition.wait`; these are **not** measured kernel sleep durations.

| CPU mask | Ingress | M0 claims | P18 claims | M0 tasks/claim | P18 tasks/claim | M0 wait calls | P18 wait calls | M0/P18 producer full retries |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 core | 8 | **5920** | **768** | **1.04** | **8.00** | **5920** | **0** | 32 / 765 |
| 1 core | 64 | 4557.5 | 769 | 1.35 | 7.99 | 4359.5 | 1 | 28 / 93 |
| 1 core | 256 | 2651 | 769 | 2.32 | 7.99 | 2167.5 | 1 | 14 / 21 |
| 1 core | 2048 | 895 | 768 | 6.87 | 8.00 | 147.5 | 0 | **0 / 0** |
| 4 cores | 8 | 768 | 768 | 8.00 | 8.00 | 3 | 0 | 6195 / 6175.5 |
| 4 cores | 64 | 768 | 768 | 8.00 | 8.00 | 3 | 0 | 6003 / 6006 |
| 4 cores | 256 | 768 | 768 | 8.00 | 8.00 | 3 | 0 | 5406 / 5409.5 |
| 4 cores | 2048 | 768 | 768 | 8.00 | 8.00 | 3 | 0 | **0 / 0** |

In the **one-core 512/ingress8** cell, M0's actual wait counts span **5892–5969** over all 20 measured rounds. Session medians **5934 / 5927 / 5920 / 5906**, with P18 median zero in **all four sessions**. M0 has a median **5921 empty batch probes**; P18 **769**. P18 has median **768 extra grace searches = 767 successful inbox recoveries + 0 fallback waits + 1 drained exit**. This directly supports a highly repeatable **small-batch / repeated empty-to-wait cycle** under one-core M0 and an almost full-batch bounded grace recovery under one-core P18. It is **not** a complete thread-interleaving timeline or a per-operation speed attribution.

**Unusually strong conservation detail:** Across **all 1,344 cases including warmups**, `park_with_outstanding = 0` and every sampled `park_waits` is in the `park_no_outstanding` bucket: at the moment immediately before the `Condition.wait` call, accepted and completed TaskRef counters are equal under the existing inbox mutex. This **does not** imply that the producer had completed admission of all future waves or that `Condition.wait` necessarily slept for a nonzero duration.

The capacity contrast is also informative: M0's one-core batch-size median increases **1.04 → 1.35 → 2.32 → 6.87** as ingress grows **8 → 64 → 256 → 2048**, with actual wait calls **5920 → 4359.5 → 2167.5 → 147.5**. Importantly, **2048 slots has no full producer retries in either arm yet M0 still makes median 147.5 wait calls**. Thus fragmenting/waiting is **not exclusively caused by the `full` producer-retry loop**.

The same small-ingress one-core pattern occurs at iterations **128 and 1024**: for ingress 8, M0 batch-claims/Wait calls **5902.5/5902.5** at 128, **5936/5936** at 1024; P18 claims approximately **769/768**, with 0–1 median waits. Under four cores (512/1024), both typically claim exactly 768 full-size batches and M0 waits three times. No 512-specific causal mechanism is demonstrated for the small relative P18 multicore penalty.

## Distinct prior uninstrumented performance evidence

Only the **separate true uninstrumented** balanced one/two/four-core XPS study, SHA-256 **`5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`**, is speed evidence here: **2,160 native matched measured ABBA pairs**, with 512/ingress8 P18/M0 median `waves_ns` **0.121511 (one CPU), 1.044167 (two), 1.036506 (four)**. That native corpus already recorded approximately **5899** original M0 wait calls under one CPU (vs P18 median 0), compared with ~3 M0 waits under multicore. Reproducing approximately the same one-core Wait-call magnitude in the new event-traced corpus strengthens the association, while instrumentation inside the existing inbox mutex still **perturbs interleavings**. The new trace `waves_ns` and `total_ns` are intentionally **excluded from any performance ranking**.

## Mechanistic scope, limitations and next gate

**Supported:** In this exact one-worker TaskRef workload, single-CPU scheduling together with tight ingress correlates with **thousands of small M0 inbox batch claims and wait entries**; P18's existing one-bounded-retry grace frequently recovers newly submitted inbox work before sleeping, yielding almost entirely eight-Task batches. Multi-core M0 and P18 both achieve mostly eight-Task batches.

**Not established:** The precise producer/worker wake and preemption timeline; which `Condition.wait` calls blocked in the OS or for how long; mutex critical-section durations; per-task cache cost; runnable queue wait; energy/fairness; performance at >1 worker, alternative TaskRef producer types or host platforms. Do **not** remove Condition semantics, promise all-core scheduler speedups, busy-spin indefinitely or infer a universal CPU-count-switching production policy from these observations.

A bounded next research stage could examine **producer admission cadence / deliberately burst-limited submissions** in another source-pinned *separate consumer*, with fixed native race, close, join and safety checks plus independent **uninstrumented one-core AND multicore ABBA tests**. Keep baseline TaskRef/Pool unchanged and document any changed producer semantics as distinct workloads. The present 512 multicore regression remains unresolved.

**Disposition: KEEP narrowly scoped P18 research; DEFER unconditional production**. Original M0 `source/`, `develop`, ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38, grandfathered R0.5 PR #35 and archived evidence unchanged.
