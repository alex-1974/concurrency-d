# P18 — Native XPS single-worker producer/ingress PI event-only audit (2026-10-14)

**KEEP narrow research / DEFER universal production adoption.** Independent audit of an **instrumented event-only** trace. **Never use PI trace `waves_ns` to rank scheduler performance**.

## Original artifact, pinned sources, integrity

- Archive `p18-pi-xps-20261014-132856.tar.gz`, SHA-256 **`8c4b0c8b23cdd99f3c9feef1c3b38412b1c9a1d6c9cdee0d642d12081410e6f8`**.
- Exact research source HEAD **`841247c886fa57ab434a4d0e7ec5cae04863d3ac`**, original unchanged M0 submission-pool Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, **LDC 1.41.0 / LLVM 19.1.7**, DUB 1.40.0, Dell XPS 15 i7-9750H. Process affinity `0,1,2,3`; producer/worker threads not individually pinned. Release binaries: M0 SHA-256 `8f5dd2aea9f779afab073c8a144e0cb064d747a9ffc257f340f6b1774f29d39b`, P18 `c5dfb1017da20c6ec814a4b3982673b8f27e7f4458d837c6335239dbf3d03958`.
- Four complete sessions alternating M0/P18 process order, eight raw logs, eight extracted CSVs and eight sysfs traces; every original raw CSV line matches the corresponding normalized file exactly. Each process has **12 cases × (2 warmups + 5 measured) = 84 rows**. **336 exact-work matched pairs**, comprising **96 warmups + 240 measured**, each with 1 worker, 2,048 TaskRefs/wave × 3 waves, iterations 128/512/1024 and ingress 8/64/256/2048. Phase, seed, case order, TaskRef checksums and stage-time conservation **PASS**.
- Independently checked: accepted = claimed = completed = 6,144 per row; `submitCalls=submitAccepted+submitFull+submitClosed`; `submitFull=retries`; successful and empty `takeBatch` calls conserve; capacity peak and occupancy histogram consistent; park-wait and grace outcomes conserve; zero foreign-steal attempts. All 2048-capacity cases have **zero producer-full retries** in both variants, measured and warmup. Runner requires native race/close preflight, but its stdout is not preserved in this archive.
- Original host/path-bearing raw archive is not included in public Git.

## The new central observation — producer yield location changes

The source-pinned P13 producer has two `Thread.yield()` paths: **after a rejected `SubmissionResult.full` admission** and **while polling completion after submitting a wave**. PI counts the second separately as `pollYields`. Increasing ingress capacity from 8–256 to 2048 makes the former vanish but shifts much of the yielding to the latter.

At **512 iterations**, medians from 20 matched event measurements **per ingress** (counts, not timing):

| Ingress | M0 full retries | M0 completion-poll yields | P18 full retries | P18 completion-poll yields | Median per-row M0/P18 combined yields |
|---:|---:|---:|---:|---:|---:|
| 8 | 6197.5 | 49 | 6184.5 | 50 | 6246.5 / 6234.0 |
| 64 | 5990.5 | 227 | 5986.5 | 227 | 6220.0 / 6214.0 |
| 256 | 5414.5 | 834 | 5402.0 | 834 | 6248.0 / 6236.5 |
| **2048** | **0** | **6333** | **0** | **6317** | **6333 / 6317** |

The number of producer `Thread.yield()` calls thus remains roughly **6,200–6,330 per 512-work measurement**, even where the full-inbox retry path is never taken. Crucially, **the yield phase and producer/worker overlap change**. Neither time spent in these phases nor the cost of an individual yield has been measured. The same shift is visible at 128 and 1024 iterations.

## Inbox, worker events and conservation

For 512 iterations, both arms generally have **768 successful batch claims, 4 empty take attempts and 772 generation reads** per measurement, at all capacities. Both reach the chosen inbox-capacity peak, including at ingress 2048 (a full queue is not the same as a failed admission). At capacity 64/256, a typical 512-work measurement records **24** accepted occupancy values ≤8 and **6120** in 9–256 for both M0/P18; at capacity 2048, around **5352** accepted occupancies exceed 256 for both arms. **No systematic rise in count of inbox operations attributable to P18 at 512 is established**; mutex wait duration and cache behavior are not measured.

At ingress 2048 and 512 iterations, all **20** P18 measured rows contain **3 additional bounded grace searches = 2 ingress recoveries + 1 drained exit** and **zero fallback parks**. All **20** M0 rows have 3 actual Condition waits; P18 has none. These event counts are not a speed explanation.

Aggregate over all **240 measured rows per arm**:

| Event | Original M0 | P18 |
|---|---:|---:|
| Producer full retries | **1,136,881** | **1,128,714** |
| Completion-poll yields | **478,727** | **480,163** |
| Actual Condition waits | **862** | **16** |
| Inbox take calls | **186,968** | **186,770** |
| Empty inbox take calls | **1,148** | **1,107** |
| Extra grace searches | 0 | **849** |
| Grace ingress recovery | 0 | **593** |
| Grace fallback after empty second scan | 0 | **18** |
| Drained-pool exits | 0 | **238** |

Grace outcomes conserve exactly: **849 = 593 + 18 + 238**, zero local/foreign-steal recoveries as expected with one worker. Event counts are perturbed by instrumentation and do not rank throughput.

## Contrasting independent performance evidence and thermal limits

Previous **uninstrumented** native one-worker ABBA archive SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63` found 512-iteration P18/M0 `waves_ns` median ratios at ingress 8/64/256/2048 of **1.0627 / 1.0392 / 1.0539 / 0.9875** (40 timing pairs per cell). Only that independent corpus is timing evidence. The new PI data show that removing full retries does **not** remove producer yielding, merely moves it into completion polling. This supports a *further hypothesis* about **producer-/worker-phase overlap and ingress residency**, not a causal proof for `Thread.yield()`, mutex contention, or any P18 speed difference.

All eight telemetry traces have **only two samples each**, **83–86°C**, with no observed package throttle-counter increment; isolated 800 MHz sysfs reported frequencies are not calibrated instantaneous worker clocks. Neither thermal qualification nor power efficiency is proved.

**Next bounded research, only if useful:** independently measure producer submission vs post-submission completion-wait *phase boundaries* or use external producer/worker scheduling observations, with source locks and carefully separated **uninstrumented ABBA speed comparison**. Do not optimize queue capacity, retry count or yield policy on PI counts alone.

**Disposition: KEEP P18 narrow research, DEFER production.** Original M0, P18 scheduling, `source/`, `develop`, prior native archives, TaskRef lifetime/`@safe TaskScope` contract, ADR status PROPOSED, Issue #17 OPEN, Draft PR #38 and grandfathered PR #35 unchanged.
