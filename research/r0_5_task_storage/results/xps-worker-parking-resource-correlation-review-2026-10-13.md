# R0.5 — Native XPS joint worker-resource / parking / wake / steal audit (2026-10-13)

**Result: worker coordination activity rises together with worker CPU and voluntary context switches as producer count grows.** Both **actual condition waits** and **failed steals** increase, and the first search after a finished wait more often finds no work. This is **joint, source-identical correlation**, not evidence that any particular condition wait or steal attempt caused a specific OS context switch or consumed a known amount of CPU. No change to queue, mutex, notification policy, worker search or task ownership is yet justified.

## Immutable evidence and provenance

- Uploaded original archive: `r05-xps-worker-parking-correlation.tar.gz`; **SHA-256 `7399fffb161305adc6adfba293af8720b97a051b2bdb612b857eaa3405d8dbff`**. Five source files in the original single top-level evidence directory: `raw.csv`, `worker.csv`, `pairs.csv`, `summary.csv`, `environment.txt`. No archive contents were executed or rewritten.
- Captured source HEAD **`1f97cf5616c67b670d2b601ba4a716822d197bd5`**, grandfathered `perf/r05-owned-task-pipeline`; LDC **1.41.0**, LLVM **19.1.7**, native Dell XPS i7-9750H. Source identity is in `environment.txt`.
- Exactly two different build hashes, with **worker** and **combined** using *the same* versioned optimized executable: unprofiled control SHA-256 `e2d2200b7374ae2497c4660d0737fe321d24f92b4902528f32bd6f2ade76d964`; worker-resource version SHA-256 `8138e0cb74d208d04957c3831a9c4c61a4c5da329d3123d6fb293485bf788701`. This is the existing full-victim R0.5 research implementation, **not** production M0. All modes use `NotificationPolicy.always`, producer-shared benchmark execution counter, retention budget512, four workers, unchanged exact task ownership and results.
- Factorial: five rounds × minimal/compute-1024 × producers 1/4/8 × freshGC/recycleTyped × three modes (**plain**, **worker**, **combined**) = **180 fresh children / 5.4 million completed Tasks**. There are **480 indexed worker records** from worker+combined, **60 matched triplets**, **12 summaries**. The initial historic wake experiment used a different source/bench counter setting, and its output must not be pooled with this source-identical sample.

## Independent dataset integrity checks

Each source CSV was parsed and recomputed against `raw.csv`:

- Exactly **180** unique factor keys and **30,000 completed Tasks** per child, **1,765 observed typed handles**, fresh nodes + reused nodes = 30,000, work checksum `21334545774983` for compute and zero for minimal. Every row declares 4 workers, `shared`, budget512 and notify `always`.
- **480** distinct per-worker records, all 0–3 indexed per measured process; sum of worker user+system CPU and voluntary switches equals each corresponding process row. Exactly one constant binary hash for plain, and the *identical other hash* for worker and combined. Plain has no worker rows; worker has worker resources but no parking events.
- In every one of the **60 combined** rows, `condition_waits=wait_returns`; returns partition into `still_blocked + exit_inbox + exit_generation + exit_drained`, and completed wait exits equal local/inbox/steal/empty/drained first searches. `executions=claimed_tasks=ingress_notifications=ingress_calls=30000`; `steal_successes <= steal_attempts`; `local_calls=local_notifications`; under `always`, ingress/local skipped notifications are both zero.
- All **60** `pairs.csv` within-round worker/plain and combined/worker ratios reproduce from raw throughputs. Each `summary.csv` median for waits, failed steals, empty/useful first searches and worker/producer CPU and switches reproduces from the five group observations.
- All **60 combined** rows have `still_blocked=0`. This narrows one proposed immediate re-wait hypothesis **for these specific cases**, not for all possible scheduling conditions. Peak process RSS is **25,720 KiB** across all 180 children and cannot discriminate memory policy benefits.

## Worker churn and resource results

These are **descriptive independent medians** of ten `combined` cases (five GC and five recycle) per workload/producers group; per-field medians need not add up, and they are not an uninstrumented causal attribution.

| Workload | Producers | Condition.wait / Task | Failed steals / Task | Empty first search after wait | Worker voluntary switches / 30k | Producer voluntary switches / 30k | Worker CPU ms / 30k | Producer CPU ms / 30k | Claimed Tasks / inbox batch |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| minimal | 1 | **0.5929** | **2.5382** | **38.88%** | **32,863** | **3,231** | **209.1** | **79.2** | **2.045** |
| minimal | 4 | **0.8152** | **3.3805** | **42.24%** | **50,305** | **25,518** | **306.9** | **210.9** | **1.551** |
| minimal | 8 | **0.8286** | **3.4459** | **42.39%** | **52,122** | **25,780** | **319.9** | **223.9** | **1.526** |
| compute-1024 | 1 | **0.3846** | **1.5938** | **18.67%** | **19,305** | **2,716** | **207.9** | **73.0** | **2.195** |
| compute-1024 | 4 | **0.5655** | **2.3924** | **33.54%** | **35,595** | **21,892** | **291.4** | **184.7** | **1.470** |
| compute-1024 | 8 | **0.6050** | **2.5818** | **33.31%** | **38,649** | **22,983** | **312.1** | **200.3** | **1.421** |

The mixed-task work is clearly short relative to scheduling coordination. At four/eight producers, inbox batches typically deliver ~1.4–1.6 tasks despite capacity for eight. This alone does **not** justify delaying publication/claiming, batching to eight, or suppressing notifications: those would alter forward progress/fairness/tail latency.

### Matched same-round increments from 1 to 4/8 producers

Within **same workload, round and policy** on **combined** mode, ten matched target-vs-one comparisons per row:

| Workload | Target producers | Δ worker CPU ms | Δ producer CPU ms | Δ worker voluntary | Δ producer voluntary | Δ actual waits | Δ failed steals | Δ empty first searches |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| minimal | 4 | **+111.6** | **+137.2** | **+19,343** | **+22,164** | **+7,572** | **+27,931** | **+3,834** |
| minimal | 8 | **+113.3** | **+145.9** | **+20,106** | **+22,419** | **+7,719** | **+29,004** | **+3,951** |
| compute-1024 | 4 | **+90.1** | **+111.7** | **+16,035** | **+19,181** | **+5,537** | **+23,765** | **+3,490** |
| compute-1024 | 8 | **+111.9** | **+133.0** | **+19,317** | **+20,209** | **+6,756** | **+29,579** | **+3,946** |

All **40 matched observations** show positive worker and producer CPU, voluntary switches and failed-steal increments; **39/40** show additional wait entries, **38/40** more empty first searches. This is strong **co-variation of measured worker state and resource use** but cannot determine what fraction of OS voluntary switches is caused by worker condition waits or whether failed steals consume most additional CPU. Different phenomena can move together due to the shared publication/worker execution schedule.

### Probe observer effect

The **worker+parking** and **worker-only** cases execute the **identical binary** but differ in runtime counter writes, so their paired throughput comparison diagnoses probe perturbation rather than an optimization:

| Workload | Producers | Median combined / worker | Median worker / plain |
|---|---:|---:|---:|
| minimal | 1 | **0.9116×** | **1.0991×** |
| minimal | 4 | **0.9952×** | **1.0285×** |
| minimal | 8 | **0.9876×** | **1.0460×** |
| compute-1024 | 1 | **0.9946×** | **0.8832×** |
| compute-1024 | 4 | **0.9970×** | **1.0326×** |
| compute-1024 | 8 | **0.9757×** | **1.0334×** |

The (combined/worker) medians are often close to one at 4/8 producers but reveal nontrivial perturbation in some groups. The plain and worker binaries differ at compile time; do not infer their ratio is a profiler-free slowdown/speedup or naively combine sources from different experimental versions. No native uninstrumented *algorithmic* performance A/B has been performed here.

## What remains unresolved / next decision

- **Supported:** higher producer concurrency is accompanied by more worker and producer resource costs, more actual condition waits, more unsuccessful steals, and more empty first post-wait searches. Worker coordination is a plausible joint area for an optimization hypothesis; neither the outer admission mutex nor condition notification alone has been established as the dominant *cause*.
- **Not supported:** every `Condition.wait` corresponds to one voluntary context switch; `notify()` cost alone implies notification coalescing is beneficial; a specific empty wake was caused by an unnecessary notify; a failed steal takes a known duration or dominates CPU; 1/4/8 producer scaling is a thread-count-independent throughput guarantee; any observed throughput ratio is a new scheduler improvement.
- **Next tight discriminator:** design a single *controlled research mechanism* only if it isolates work acquisition coordination (e.g. count worker search-cycle entries or compare an explicitly controlled notification/steal-policy variant), and match **identical TaskRef/root/backpressure/close/fairness and idle tail-latency**. Prefer first determining whether the already existing `WorkerParkingStats` counters provide enough accounting to build a per-successful-acquisition metric. Preserve negative [waiter-aware native A/B](xps-notification-ab-review-2026-10-11.md) evidence: skipping notifications previously gave no stable throughput advantage.
- **Engineering disposition:** KEEP default `freshGc`, `NotificationPolicy.always`, full-victim traversal, existing mutex/generation wake predicate and ownership guarantees; DEFER typed recycler, lock-free inbox, forced batching and blind spin-before-park. Do **not** merge grandfathered Draft PR #35 wholesale to `develop`; Issue #20 remains open, and no other workspace repo is written.
