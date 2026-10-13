# R0.5 — Dell XPS worker parking/wake vs producer/worker CPU (2026-10-13)

**Result: native same-source evidence now connects (descriptively) additional worker voluntary context switches and worker CPU time with more real condition waits, more failed steals and more empty first searches after wait exits as producer concurrency increases.** The added cost is still shared between producer and worker threads. The existing shared execution counter had already been controlled separately; the benchmark's original counter choice alone does not explain the producer-scaling failure. **No individual lock, futex, notification or steal is shown to have caused a specific context switch, nor is a new scheduling algorithm validated. KEEP the normal fresh-GC and `NotificationPolicy.always` contracts; DEFER lock, queue, parking and recycler redesign.**

## Raw evidence and exact source identity

- User-uploaded original `r05-xps-worker-parking-correlation.tar.gz`; archive SHA-256 **`7399fffb161305adc6adfba293af8720b97a051b2bdb612b857eaa3405d8dbff`**. The tar contains one top-level `r05-xps-worker-parking-correlation/` directory and five unmodified original files: `raw.csv` SHA `4754bb7912ecd9ca92d7a5a6d48416c435a467d1d5f713f5ef30b8db6709f402`, `worker.csv` SHA `965116a72e59fc3d4cce963197ecaaa059b2707b6784dad4e6c6ecfeed6d0666`, `pairs.csv` SHA `aa0fb78d3b01fd10ca2ffd7b6058d9cf2ee24e2ffb20f323dcc3623b157b504f`, `summary.csv` SHA `4a4846f04dc3f853dd1d4c08e064b3ec87847d20ddd279e13799e23a18773126`, and `environment.txt` SHA `90de411cca186148b0d70f7bd7d6aef36bdabbca120c8f233d1a253c42868e15`. These original research artifacts were read, rechecked and **not rewritten into Git**.
- Exact measured research HEAD: **`1f97cf5616c67b670d2b601ba4a716822d197bd5`**, grandfathered `perf/r05-owned-task-pipeline` branch. The original environment records `git status --short --untracked-files=no` empty; this does **not** establish absence of untracked native evidence files.
- Native Dell XPS Intel **Core i7-9750H**, 6 physical / 12 logical CPUs, Linux **6.17.0-22-generic x86-64**, glibc 2.43, **LDC 1.41.0** / LLVM 19.1.7 / DMD frontend 2.111.0. CPU governor `powersave`; `lscpu` captured **90% instantaneous CPU scaling**, **not** the mean operating clock of any run. No trace of temperatures, CPU affinity, current power source or competing host load.
- Two optimized release executables from the same research source: **plain** full-victim control SHA-256 `e2d2200b7374ae2497c4660d0737fe321d24f92b4902528f32bd6f2ade76d964`; **worker** thread-start/stop-only measurement SHA-256 `8138e0cb74d208d04957c3831a9c4c61a4c5da329d3123d6fb293485bf788701`. The third **combined** mode runs the **same worker executable SHA-256** but enables the preexisting runtime `parkingProfile` counter updates. These are not three production executor variants.
- In **all modes**: `R05FullVictimSweep`, four worker threads, retention budget512, shared benchmark execution counter, 64-slot ingress, same minimal and compute-1024 mixed typed/GC-visible/void Tasks, normal/default `freshGc` or experimental `recycleTyped`, and `NotificationPolicy.always`. No Admission/Inbox stopwatch or per-task timestamp. Enabling **combined** activates *preexisting* counter increments in the worker/inbox hot path and thus remains observer-perturbed.
- Matrix: **5 rounds × 2 workloads × 3 producer counts (1/4/8) × 2 storage policies × 3 modes = 180 fresh Linux child processes × 30,000 actually completed Tasks = 5.4 million Tasks**. `worker` and `combined` each contribute 60 child processes × four worker snapshots, **480 independently indexed worker records**.

## Independent audit from original CSV bytes

All five original files were parsed afresh; `raw.csv` contains **180 rows / 71 columns**, `worker.csv` **480 rows / 14 columns**, `pairs.csv` **60 rows / 22 columns**, `summary.csv` **12 rows / 14 columns**.

- **Complete factorial**: 180 unique (`round,mode,workload,producers,policy`) process keys, 60 in each mode; 120 worker-capable cases each have exactly the four distinct indices 0–3. Identical worker-mode binary hash for both `worker` and `combined`; distinct plain hash. All 180 are `completed=tasks=30000`, `fresh_nodes+reused_nodes=30000`, `observed_handles=1765`, shared counter, `always` notification and correct budget/worker identities. Compute checksum is **21334545774983** and minimal checksum **0** across all corresponding cases; child external wall is no shorter than measured internal benchmark wall.
- Every one of the **120 worker-capable process rows** exactly matches the independently re-aggregated worker `cpu_us`, voluntary and involuntary context switches from its four individual `worker.csv` rows. For `plain`, all worker and parking fields are truly missing (blank), not imputed as zero. `worker` has worker counters but no parking counts; `combined` has both.
- In each of the **60 combined-mode cases**, `condition_waits=wait_returns`; the wait returns partition into still-blocked retries and three final-predicate states; those final exits partition exactly into first local/inbox/steal/empty/drained searches. All 60 also satisfy `steal_successes <= steal_attempts`, `executions=claimed_tasks=ingress_notifications=30000`, `ingress_calls=30000`, `ingress_skipped=0`, `local_calls=local_notifications`, `local_skipped=0`, `claimed_batches>0`, `peak_queued<=64`, and the stored per-task/per-batch and useful/empty fractions recompute directly. These are **accounting conditions, not a proof of notification-to-wakeup causality**.
- In this native corpus, **`still_blocked=0` and `useful_local=0` in all 60 combined runs**, matching the earlier *qualitative* wake-outcome evidence; all 60 have positive final-wait denominators. An immediate still-blocked re-wait loop cannot explain the recorded churn **within this experiment**. In the current model useful first searches arose by inbox or steal, not by owner-local discovery.
- Every value in **60 round-matched three-mode pairs** (`worker/plain`, `combined/worker`, copied worker/producer CPU and switches, combined wake counts and fractions) was independently recomputed from the raw cases. The **12 five-round `summary.csv` group medians** (condition waits/Task, failed steals/Task, empty/useful fractions, worker/producer CPU and switches, mode rate ratios) were also recomputed and agree exactly to floating-point tolerance.
- The `wait4` peak RSS is the same **25,720 KiB in all 180 processes**; this short workload cannot distinguish retention policy memory effects. The signed whole-child minus producer minus worker CPU residuals in worker-capable modes are **6,688–40,750 µs**; not precise independent main/GC CPU. No perf event, kernel futex call attribution, duration of a wait, or notify-to-run latency was recorded.

## A. Counts and resource use rise together as producer concurrency increases

Below are **independent per-column descriptive medians** over the **ten `combined` runs** in each (workload, producers) group (5 freshGC + 5 recycle). There is one identical source revision and worker binary; grouping the two policies does **not** establish that they are equivalent or new iid population samples.

| Workload | Producers | Actual condition waits / task | Failed steals / task | Empty first search after final wait | Claimed Tasks / inbox batch |
|---|---:|---:|---:|---:|---:|
| minimal | 1 | **0.593** | **2.538** | **38.88%** | **2.045** |
| minimal | 4 | **0.815** | **3.380** | **42.24%** | **1.551** |
| minimal | 8 | **0.829** | **3.446** | **42.39%** | **1.526** |
| compute-1024 | 1 | **0.385** | **1.594** | **18.67%** | **2.195** |
| compute-1024 | 4 | **0.566** | **2.392** | **33.54%** | **1.470** |
| compute-1024 | 8 | **0.605** | **2.582** | **33.31%** | **1.421** |

The first search is scored **after a final wait-loop exit**, not after every notification, and useful/empty categories exclude drain/shutdown. It is possible for another worker to claim work before the awakened one searches. Do **not** read 42%/33% empty as 42%/33% unnecessary `Condition.notify()` calls. The claim capacity is eight, but the observed inbox occupancy at claim time is generally only ~1.4–1.6 Tasks/batch under four/eight producer contention. Enlarging the claim buffer alone cannot create larger batches.

| Workload | Producers | Four worker voluntary switches / 30k Tasks | Producer voluntary switches / 30k Tasks | Four worker CPU ms / 30k Tasks | Producer CPU ms / 30k Tasks |
|---|---:|---:|---:|---:|---:|
| minimal | 1 | **32,863** | **3,231** | **209.1** | **79.2** |
| minimal | 4 | **50,305** | **25,518** | **306.9** | **210.9** |
| minimal | 8 | **52,122** | **25,780** | **319.9** | **223.9** |
| compute-1024 | 1 | **19,305** | **2,716** | **207.9** | **73.0** |
| compute-1024 | 4 | **35,595** | **21,892** | **291.4** | **184.7** |
| compute-1024 | 8 | **38,649** | **22,983** | **312.1** | **200.3** |

Worker CPU and worker context switching increase at higher producer counts, **as do producer CPU and producer switches**. The process does less useful Task throughput in spite of greater aggregate CPU use. These cumulative thread metrics are *not* interchangeable with wall-time-per-task nor do they identify which mutex, instruction, Condition or GC phase consumed the CPU.

The descriptive median of each combined child's `worker_voluntary / condition_waits` is between **~1.68 and ~2.12** across the listed workload/producer groups (full observed range **1.622–2.196**), confirming there are substantially more voluntary worker context switches than accounted `Condition.wait()` entries. This quotient **is not** a percentage of switch causes and **must not** be used to infer that a specific wait produces ~2 switches. Other blocking operations occur, and the thread-level resource sample has a different accounting contract from the event counter.

### Same-round / same-policy increments, more defensible than grouped-median subtraction

Compare each combined-mode four/eight-producer case with its **one-producer, same-round, same-policy and same-workload** combined-mode case (ten pairs per target). The table lists **medians of paired differences**; percentages are changes in percentage points.

| Workload | 1 -> producers | Delta condition waits / Task | Delta failed steals / Task | Delta worker switches / 30k Tasks | Delta producer switches / 30k Tasks | Delta worker CPU ms | Delta producer CPU ms | Delta empty-search share |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| minimal | 4 | **+0.252** | **+0.931** | **+19,343** | **+22,164** | **+111.6** | **+137.2** | **+3.73 pp** |
| minimal | 8 | **+0.257** | **+0.967** | **+20,106** | **+22,419** | **+113.3** | **+145.9** | **+3.99 pp** |
| compute-1024 | 4 | **+0.185** | **+0.792** | **+16,035** | **+19,181** | **+90.1** | **+111.7** | **+14.05 pp** |
| compute-1024 | 8 | **+0.225** | **+0.986** | **+19,317** | **+20,209** | **+111.9** | **+133.0** | **+14.62 pp** |

- **All 40** matched comparisons show positive differences in worker CPU, producer CPU, worker voluntary switches, producer voluntary switches, and failed-steal events/Task. **Condition waits/Task increased in 39/40**, not 40/40; the exception is one minimal 4p/1p case. The covariance is consistent with a combined worker/producer coordination problem, not with one grossly overloaded worker or only a shared execution counter.
- The paired deltas reveal that the producer-side increases in CPU and context switching remain material while worker wake/search churn also increases. Any claim that a worker-side parking change **alone** will recover all scaling is currently unsupported.
- These are **correlated factor/round observations**, not 40 independent randomized participants or a causal controlled modification of one mutex. Power, thermal and round-order conditions were not tightly controlled.

## B. Storage policy detail and old-source comparability

For clarity, five-run medians in each storage policy of the existing counters (per Task):

| Workload | Producers | GC condition waits | Recycle condition waits | GC failed steals | Recycle failed steals |
|---|---:|---:|---:|---:|---:|
| minimal | 1 | **0.601** | **0.544** | **2.587** | **2.372** |
| minimal | 4 | **0.836** | **0.788** | **3.413** | **3.284** |
| minimal | 8 | **0.856** | **0.803** | **3.546** | **3.408** |
| compute-1024 | 1 | **0.403** | **0.366** | **1.655** | **1.533** |
| compute-1024 | 4 | **0.580** | **0.551** | **2.438** | **2.346** |
| compute-1024 | 8 | **0.640** | **0.565** | **2.687** | **2.451** |

Recycling counts appear somewhat lower in these group medians, but the policies differ in record-memory behavior and *neither the event frequency nor the event cost is an isolated intervention*. **This is not evidence that recycling is generally faster**. `freshGc` remains default.

The [native 2026-10-11 wake-to-search study](xps-wake-outcomes-review-2026-10-11.md) used a **different source revision and striped execution counters**, so its GC minimal/4p **0.8558 waits/Task**, **2.5153 failed steals/Task**, **44.5% empty** and compute/4p **0.6206**, **1.8257**, **35.6% empty** are **historical context**, not same-source replicates. This new study controls source and directly collects worker resource and existing worker-state statistics **within the same combined process**. The separate [2026-10-12 worker resource](xps-worker-resources-review-2026-10-12.md) measurements remain intact and source-different; do not merge their raw samples with this archive.

## C. Profile observer effect and continued negative scaling

The **plain** release control differs in codegen from the worker-resource build. The **worker** and **combined** observations do use the *same* binary, but `combined` adds runtime parking counter work under existing locks. These same-round rates describe measurement perturbation and scheduling noise, **not an algorithm speedup**.

- Among **60 worker-vs-plain** pairs, descriptive median `worker/plain` throughput **1.03864×**, worker build nominally faster in **45/60**, pair range **0.6456–1.4229×**. There is substantial particularly single-producer source and host noise.
- Among **60 combined-vs-worker** pairs, descriptive median `combined/worker` throughput **0.98057×**, combined nominally faster in **20/60**, pair range **0.6194–1.3722×**. The slight apparent median slowdown of parking profiling and its wider variance **cannot** be naively subtracted to obtain per-event costs.
- Across the total **120** per-round higher-versus-one-producer throughput ratios (5 rounds × 2 workloads × 2 policies × 3 modes × two targets), **all 120 are <1.0**, regardless of profiling mode; combined-case magnitude should not be transferred to the other builds.

Descriptive producer-scaling median ratios, each over ten within-round/policy pairs:

| Workload | Mode | 4 producers / 1 | 8 producers / 1 |
|---|---|---:|---:|
| minimal | plain | **0.613×** | **0.563×** |
| minimal | worker | **0.543×** | **0.516×** |
| minimal | combined | **0.580×** | **0.581×** |
| compute-1024 | plain | **0.581×** | **0.603×** |
| compute-1024 | worker | **0.680×** | **0.659×** |
| compute-1024 | combined | **0.702×** | **0.646×** |

A higher `combined` rate in one cell than the `worker` mode is **not** a benefit from profiling or a changed scheduler. The same data prove only that increasing producer count in this short, mixed four-worker task setup is strongly associated with greater overhead and lower end-to-end throughput.

## Next responsible discriminator

This experiment already answers the original narrow question:
**worker voluntary switches rise concurrently with actual worker condition waits, failed steals, and (especially for compute) empty first post-wait searches**. It rules out describing worker switches as *only* producer admission overhead or *only* worker condition waits. **No further duplicate event counter is justified.**

A controlled next *research* slice should test **one change at a time** while retaining the full original TaskRef/GC strong-root-before-publication, bounded rejection, close/join linearizability, worker full-victim traversal, and generation-based lost-wakeup prevention. Before selecting a candidate, review the existing [batch-size/worker-search negative evidence](xps-intermediate-batch-and-search-review-2026-10-11.md), [notification-policy A/B](xps-notification-ab-review-2026-10-11.md) and [rotating victim study](xps-rotating-victim-review-2026-10-11.md) so previously disqualified mechanisms are not casually proposed again.

Candidate **measurement**, not yet an optimization: use a longer constant-source uninstrumented workload and unprivileged passive per-thread scheduling sampling (e.g. Linux `/proc/<pid>/task/*/schedstat` where supported) to study actual CPU-run/wait distribution, or investigate a narrowly specified high-producer admission/worker handoff mechanism with a *separate* semantically equivalent uninstrumented A/B and low-arrival wake-tail/lifetime shutdown gates. Neither has been performed in this archive.

**Engineering disposition:** KEEP `freshGc` default and `NotificationPolicy.always`; defer recycler, new mutex, lock-free inbox, notification suppression and spin-before-park. Retain grandfathered Draft [PR #35](https://github.com/alex-1974/concurrency-d/pull/35) and open [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20). **No broad research merge or write to `develop`, `main` or another workspace repository.**