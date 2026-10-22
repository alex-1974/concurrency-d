# P18 — complete native Focus512 event-only trace audit (2026-10-14)

**Disposition: KEEP narrow research / DEFER general production.** This is the independent analysis of a source-pinned, **instrumented event-only** trace. Its elapsed times **must not** be interpreted as M0/P18 performance results.

## Provenance and exact evidence

- Input native XPS archive: `p18-focus512-trace-20261014-122411.tar.gz`; SHA-256 **`14161de32b9119323994eab22c2e08097880c4e0238421eead93677130af8004`**. Original raw archive retained outside Git (machine identifiers and local paths).
- Manifest research source **`6217bc627070ee1dcef6e3a0a6e73439980b2b94`**, original unchanged production-M0 `submission_pool.d` Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, LDC 1.41.0 / LLVM 19.1.7, DUB 1.40.0, Dell XPS 15 i7-9750H, CPU process affinity `0,1,2,3` (no individually pinned worker threads).
- Two separately precompiled release trace binaries differ: M0 `f700cf5bc3e68048a66c2c3d5f46cf8ecab66d488feca8fc7294be359ac4f17b`, P18 `7a99f289fbfb03762a42cb3d6436004de1a860d4f9906d89c3a2dc81e8d4714b`.
- Four complete sessions, alternating trace-M0/trace-P18 whole process order. **Eight process raw logs, eight exact CSVs, eight sysfs thermal traces.** Each process has exactly **27 settings × (2 warm-ups + 5 measured) = 189 rows**. All raw stdout CSV rows match normalized CSV byte-for-byte. **756 matched TaskRef rows**, comprising **216 warm-up + 540 measured matched pairs**; exact phase/round/seed/workers/count/waves/iterations/ingress/checksum, with valid stage conservation. Native runner requires race preflights to succeed, but their stdout is not retained in the archive for independent review.
- Each case: 2,048 Tasks × three waves, workers 1/2/4, ingress 8/64/256, iterations 128/512/1024. All counters nonnegative, joined before read, actual Condition waits match the original parkCount, accepted execution and per-worker bounds conserve tasks, and **each grace search belongs to exactly one outcome category**. M0 never records a grace event.

## Recorded event distribution (540 measured rows per arm)

| Event | Original M0 | P18 trace |
|---|---:|---:|
| Additional bounded searches | 0 | **28,915** |
| Successful local recovery | 0 | **0** |
| Successful ingress recovery | 0 | **13,732** |
| Successful foreign steal after retry | 0 | **3,931** |
| Exhausted extra search before park protocol | 0 | **10,426** |
| Found pool drained/closed | 0 | **826** |
| Total foreign steal attempts | 89,841 | **188,015** |
| Successful foreign steals | 27,820 | **44,168** |
| **Failed foreign steal attempts** | **62,021** | **143,847** |
| Actual Condition.wait entries | 13,025 | **8,245** |
| Parks with no outstanding work | 6,997 | 6,102 |
| Parks with outstanding accepted work | 6,028 | 2,143 |
| Producer retries | 1,960,548 | 1,832,317 |

**Exactly 28,915** grace events conserve: `0 + 13,732 + 3,931 + 10,426 + 826`. Second search recovered **17,663 / 28,915 = 61.09%** of the time (ingress 47.49%, steals 13.59%). Failed extra searches 36.06%, drained exits 2.86%. Local recoveries **zero in this recorded workload**, not a proof they cannot occur under other workloads. The additional work could have been scheduled later by original M0; counter success is not a demonstrated throughput improvement.

P18 raises failed steals by **81,826**, while observed actual waits fall by **4,780** and producer retries by **128,231** in these *instrumented* processes. These counts are **not units of time**. They cannot be used to normalize, explain away or replace the independent uninstrumented wave-latency corpus.

## Task size and recovery

| Iterations | Extra searches | Recovered work | Recovery percentage | Exhausted second scans | Drained exits |
|---:|---:|---:|---:|---:|---:|
| 128 | 15,230 | 10,480 | **68.8%** | 4,479 | 271 |
| **512** | **6,039** | **3,289** | **54.5%** | **2,469** | **281** |
| 1024 | 7,646 | 3,894 | **50.9%** | 3,478 | 274 |

Success falls from 128 to 512, **but also falls further at 1024**, where the independent *uninstrumented* A/B/B/A result favored P18 overall. Recovery rate by itself does **not** establish why 512 performs worse.

## Multiworker counterexamples (event totals; 60 matched cases per row)

| Iterations | Workers | Failed steals M0/P18 | Actual parks M0/P18 | P18 recovered/searches |
|---:|---:|---:|---:|---:|
| 128 | 1 | 0/0 | 247/9 | 237/306 |
| 128 | 2 | 3,445/4,630 | 2,405/377 | 3,114/3,852 |
| 128 | 4 | 43,032/63,834 | 6,586/2,789 | 7,129/11,072 |
| **512** | **1** | **0/0** | **180/3** | **120/181** |
| **512** | **2** | **603/925** | **442/118** | **420/662** |
| **512** | **4** | **8,918/31,546** | **1,518/2,002** | **2,749/5,196** |
| 1024 | 1 | 0/0 | 180/0 | 119/180 |
| 1024 | 2 | 522/601 | 390/73 | 209/385 |
| 1024 | 4 | 5,501/42,311 | 1,077/2,874 | 3,566/7,081 |

With **four** workers, instrumented P18 triggers **more actual waits than M0 at 512 and 1024**, so it does not universally prevent parking. Foreign stealing **cannot be the sole cause** of the 512-work regression: one-worker P18 showed a small slowdown in the independent uninstrumented ABBA corpus but neither one-worker scheduler makes any foreign-steal attempt. At four workers, additional failed steals are **even more numerous at 1024** than 512, where P18 nevertheless performed better in the uninstrumented corpus. This warns against causal conclusions from counts alone.

The four-worker 512 traced park increase also contrasts with the uninstrumented ABBA median park decrease. Distinct independently scheduled trace arms are **not the same machine execution**, and instrumentation modifies execution interleavings.

## Thermal/evidence limits and disposition

All eight 500-ms process traces contain four samples, with package temperatures **68–83 °C**, **zero observed package-throttle counter increases**, and sampled CPU reported rates around 4.0–4.30 GHz. There is no fixed per-worker clock proof or watt/joule measurement.

The independent *uninstrumented* full ABBA archive remains the speed reference: SHA-256 `df4b1e1f60a0f95d4e7a6523f8af3e390e1138402fa1ab3e0718a77f84a61da6`, **1,080 matched pairs**, P18/M0 `waves_ns` medians **0.9559 / 1.0119 / 0.9829** at 128/512/1024, including major session-to-session variation and a single observed throttling process. No event-to-duration causality established.

**KEEP narrow short-burst research; DEFER unconditional production**. If research continues, isolate *single-worker ingress/producer/park 512-work behavior* separately from cross-worker stealing. Any policy/optimization decision requires further uninstrumented native evidence and lifetime/race semantics. Production M0, `develop`, grandfathered R0.5 PR #35, Issue #17 OPEN, ADR-0001 PROPOSED, PR #38 DRAFT, public `@safe TaskScope` NO-GO remain unchanged.
