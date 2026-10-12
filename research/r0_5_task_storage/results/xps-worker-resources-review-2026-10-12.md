# R0.5 — Dell XPS producer/worker thread-boundary resource attribution (2026-10-12)

**Finding and research disposition:** At 4 and 8 concurrent producers, **both the producer threads and the four worker threads** show large additional CPU and voluntary context-switch costs per 30,000 completed mixed Tasks compared with one producer. Across matched rounds, the **incremental overhead is approximately half producer-side and half worker-side** in both minimal and compute-1024 workloads. Worker CPU distribution is **well balanced**; one unfairly monopolizing worker is not implicated by these measurements. **KEEP `freshGc`, `NotificationPolicy.always`, admission/GC-root/lifetime ordering, complete foreign-victim sweep and current wake-generation contract.** No producer-only or worker-only architectural redesign is justified by these counters. Research R0.5 remains distinct from the production M0 executor.

## Source-pinned original evidence

- User-supplied `r05-xps-worker-resources.tar.gz`; exact archive SHA-256 **`3c5997dee272cac7c02d887aa265dbd977a3315d55bf02170701a272aab4bbbe`**. It contains **six** data files under a single `r05-xps-worker-resources/` directory: `raw.csv`, `worker.csv`, `pairs.csv`, `summary.csv`, `producer_scaling.csv`, `environment.txt`. Files were read from the archive and independently audited; neither source files nor the original archive were rewritten or committed.
- Exact measured Git HEAD **`c992ad55dd0587f6957261f9077e7f80b3f91f8e`** on grandfathered `perf/r05-owned-task-pipeline`. `git status --short --untracked-files=no` empty at measurement (not a claim that the checkout contained no untracked evidence). This revision implements the specific opt-in thread-boundary probe and [measurement protocol](../r05-worker-lifecycle-resource-profiling.md).
- Two **different LDC 1.41.0 / LLVM 19.1.7 release executables**: baseline `task-pipeline-mixed-full-victim-sweep` SHA-256 **`e2d2200b7374ae2497c4660d0737fe321d24f92b4902528f32bd6f2ade76d964`** and opt-in `R05WorkerThreadResources` `task-pipeline-mixed-full-victim-worker-resource` SHA-256 **`8138e0cb74d208d04957c3831a9c4c61a4c5da329d3123d6fb293485bf788701`**. Both use full N-slot victim sweep, `instrumentation=off`, `parking=off`, `notify=always`; no Admission/Inbox/per-Task timers. **Do not label these executables codegen-identical.** The prior 2026-10-12 shared/striped native binary hash differs from both, so do not pool campaigns as exact same-executable replications.
- Dell XPS **Intel Core i7-9750H** (six cores, 12 logical threads), Linux **6.17.0-22-generic x86-64** / glibc 2.43, DUB 1.40.0; CPU governor **`powersave`**. One `lscpu` CPU scaling snapshot is **68%**, **not** a sustained per-run CPU frequency. No validated temperature/energy/power-mode trace, pinning or background load.
- Five rounds × **two workloads** (`minimal`, `compute-1024`) × **three producer counts** (1, 4, 8) × **two storage policies** (`freshGc`, `recycleTyped`) × **two sampling modes** (original off and worker start/exit sampling) = **120 independent fresh child processes**, **30,000 completed Tasks/process, 3.6 million Tasks total**. Four workers, retention budget512, shared execution counter, unchanged mixed typed/GC-visible/void payloads and `NotificationPolicy.always`.
- Of these, **60** worker-mode child processes report exactly **four worker thread-local resource snapshots each = 240 independently indexed worker rows**. Other 60 off-mode processes have no worker rows. The worker resource helper calls Linux `getrusage(RUSAGE_THREAD)` **once before** and **once after** `workerLoop()`, writes each worker's private slot, and exposes an after-join copy. The producer samples already existed and bracket its producer loop. Whole-child `wait4` metrics cover the entire process's worker/producer/other runtime activities. The worker probe does not trace individual waits, steals or task executions.

## Independent cross-file integrity audit

Read all six files from the original archive and recomputed:

- `raw.csv`: **120 unique** (`round,workload,producers,policy,mode`) keys and complete expected factorial; every row has `completed=30000`, `fresh_nodes+reused_nodes=30000`, `observed_handles=1765`, four workers, budget512, shared counter and positive throughput. All runs have external wall >= benchmark internal time, and every build-mode row has its designated binary SHA.
- `worker.csv`: **240 unique** (`round,workload,producers,policy,worker_index`) keys, exactly indices **0–3** for each worker-mode case; the six individual worker resource fields, `worker_cpu_us`, minima, maxima and max/min ratio **reconcile exactly** to the corresponding `raw.csv` aggregate row. Off-mode worker fields are blank, never inferred.
- Compute-1024 deterministic checksum is **`21334545774983`** for all relevant cases, independent of policy, producer count or mode; minimal checksum is 0 by contract. Runtime check also verifies accepted/executed/completed and typed/GC-visible observations; these checks are specific to this workload, **not a new general ownership or move-only-destructor guarantee**.
- `pairs.csv`: **60** exact same-round same-workload/producer/policy off-vs-worker comparisons, with ratios and copied CPU/switch columns independently recalculated from the source raw rows.
- `summary.csv`: **12** exact groups, each **five rounds**, with the median mode ratio and worker/producer CPU and voluntary-switch totals recalculated.
- `producer_scaling.csv`: **80** true within-round 4/1 or 8/1 scaling ratios, by mode/workload/policy; every ratio recalculates from its two exact raw process records.
- The 60 worker mode cases all have **positive** signed other-process CPU residual (`child - producer - worker`) **9,895–50,355 µs** and voluntary-switch residual **108–489**. Residuals are not independently verified main-thread or GC activity and may be affected by snapshots' different boundaries and microsecond resolution.
- All **120** `wait4` process peak-RSS samples equal **25,016 KiB**, so this short study cannot distinguish GC/recycler memory policy savings. No major faults reported. CPU/switch metrics are nonnegative; the environment cannot supply `perf` kernel lock/futex call stacks or worker wake-to-run latency.

## A. Pooled per-case native CPU and voluntary switching: worker and producer, separately

The following numbers are **medians of ten worker-mode child processes** (five GC plus five typed recycler) per (`workload,producer-count`) group. They are **medians of each column separately**, so do not require summed column medians to equal the child median.

### CPU seconds for each 30,000-Task workload

| Workload | Producers | Producer CPU seconds | **Four worker CPUs, summed seconds** | Whole-child CPU seconds |
|---|---:|---:|---:|---:|
| minimal | **1** | **0.099** | **0.253** | **0.370** |
| minimal | **4** | **0.289** | **0.414** | **0.722** |
| minimal | **8** | **0.307** | **0.448** | **0.777** |
| compute-1024 | **1** | **0.068** | **0.214** | **0.322** |
| compute-1024 | **4** | **0.250** | **0.387** | **0.677** |
| compute-1024 | **8** | **0.275** | **0.432** | **0.749** |

CPU seconds are the **sum across concurrent threads**, not end-to-end wall seconds. With eight producers compute-1024, worker CPU increases from ~214 to ~432 ms per 30,000 completed Tasks, while producer CPU increases from ~68 to ~275 ms. A large fraction of *total* CPU time is in workers, but producers account for a much larger **share** at 4/8 producers than at one.

The median **per-process shares** (not ratio of independently pooled medians) show:

| Workload | Producers | Four workers / child CPU | Producers / child CPU |
|---|---:|---:|---:|
| minimal | 1 | **68.9%** | **26.4%** |
| minimal | 4 | **57.6%** | **40.1%** |
| minimal | 8 | **58.0%** | **39.8%** |
| compute-1024 | 1 | **66.6%** | **21.4%** |
| compute-1024 | 4 | **57.2%** | **36.7%** |
| compute-1024 | 8 | **57.1%** | **36.9%** |

### Voluntary context switches for each 30,000-Task workload

| Workload | Producers | Producer voluntary switches | **Four workers summed switches** | Whole-child voluntary switches |
|---|---:|---:|---:|---:|
| minimal | **1** | **3,052** | **30,297** | **33,578** |
| minimal | **4** | **25,831** | **51,033** | **77,283** |
| minimal | **8** | **24,031** | **50,604** | **74,404** |
| compute-1024 | **1** | **2,415** | **14,712** | **17,414** |
| compute-1024 | **4** | **22,272** | **36,077** | **58,451** |
| compute-1024 | **8** | **22,255** | **36,896** | **59,421** |

Per-run descriptive median **worker shares of voluntary context switches**: minimal 1/4/8 producers **90.1% / 66.4% / 67.8%**; compute-1024 **85.3% / 61.6% / 61.8%**. Workers remain the absolute majority, but producer contribution changes substantially as the producer count rises.

The signed `whole-child - producers - workers` voluntary residual is small in all worker-mode processes: median ~271 switches/child; it is **not** evidence that remaining main/GC work has zero cost, since it excludes no unprofiled source and counters have different sampling boundaries.

## B. Same-round increments attribute the additional burden approximately evenly

For each workload, pair each 4/8-producer **worker-mode** process with the one-producer worker-mode process of the *same round and same storage policy*, yielding **ten matched process comparisons per target count**. Medians of the **individual within-round differences**:

| Workload | From 1 to | Δ worker CPU ms | Δ producer CPU ms | Δ worker voluntary switches | Δ producer voluntary switches |
|---|---:|---:|---:|---:|---:|
| minimal | **4** | **+164.1** | **+193.8** | **+21,163** | **+22,798** |
| minimal | **8** | **+199.5** | **+213.4** | **+20,428** | **+20,864** |
| compute-1024 | **4** | **+167.7** | **+175.2** | **+21,006** | **+19,730** |
| compute-1024 | **8** | **+207.8** | **+202.2** | **+21,666** | **+19,840** |

All **40 matched process pairs** show positive worker **and** producer CPU and voluntary-switch increases. The *other-process* residual differences are small, variably signed, and cannot be assigned to GC versus main-loop work.

These paired-increment medians are a better basis for saying **incremental overhead is distributed across both producer and worker groups** than subtracting pooled medians or inferring a scheduler cause from one group's absolute size. An increase in context switches does not identify a specific mutex, condition, yield, user-vs-system CPU source, stolen-work attempt or GC park event.

## C. Worker CPU distribution shows no single hot worker

Per worker-mode process, calculate the maximum worker CPU divided by minimum worker CPU, then take the five-GC/five-recycle median:

| Workload | Producers | Median max/min worker CPU |
|---|---:|---:|
| minimal | **1** | **1.041×** |
| minimal | **4** | **1.036×** |
| minimal | **8** | **1.022×** |
| compute-1024 | **1** | **1.038×** |
| compute-1024 | **4** | **1.041×** |
| compute-1024 | **8** | **1.009×** |

All observed within-process max/min ratios were below **1.115×**, and at compute/8 producers at most **1.020×** across the ten process cases. Under this workload CPU *time* is well distributed, so a **single CPU-dominant worker imbalance** is not an obvious explanation for negative scaling. This does **not** assert evenly distributed **useful** tasks or fair wake-to-run/tail latency, which were not observed with this probe.

## D. Native throughput and probe observer effect

The baseline **OFF** and worker-resource **ON** executables differ at compile time, and all modes have CPU/governor/drift noise. **Do not call the worker probe faster, or mix these rates as a single unbiased speed sample.**

Descriptive medians of **five within-round `worker-profiled/off` throughput ratios**, pooled only to illustrate both policies (ten samples per workload/producer group):

| Workload | Producers | Descriptive median worker/off ratio | Worker build faster /10 |
|---|---:|---:|---:|
| minimal | **1** | **1.059×** | 5 |
| minimal | **4** | **1.001×** | 5 |
| minimal | **8** | **1.010×** | 7 |
| compute-1024 | **1** | **1.030×** | 6 |
| compute-1024 | **4** | **1.030×** | 6 |
| compute-1024 | **8** | **1.014×** | 8 |

Across the 60 separately paired `worker/off` ratios, pooled **descriptive median `1.01442×`**, range **0.81290–1.47044×**, worker builds nominally faster **37/60**. This proves only that the two executables/measurement environments vary; the probe adds two `getrusage` samples per worker, **not a production throughput optimization**. Do not subtract the ratio as a linear probe overhead estimate. The min/max values signal substantial variability, particularly one-producer cases.

Negative producer scaling persists in both distinct executables. Among the **80** per-round scaling ratios (4/1 or 8/1; 2 workloads × 2 policies × 2 modes × 5 rounds), **all 80 are below 1.0**, with the greatest only **0.83905×**. Medians pooled descriptively over both policies:

| Workload | Mode | Median 4p/1p throughput | Median 8p/1p throughput |
|---|---|---:|---:|
| minimal | off | **0.572×** | **0.497×** |
| minimal | worker | **0.543×** | **0.508×** |
| compute-1024 | off | **0.590×** | **0.524×** |
| compute-1024 | worker | **0.526×** | **0.471×** |

Because the work units are fixed, additional producer concurrency is associated with **lower useful task throughput** and higher CPU and voluntary-switch totals on both sides. This campaign is **not** a controlled 1-vs-8 contention microbenchmark independent of scheduler startup/cleanup; the measured interval includes task publication, worker execution, joins and release.

These throughput magnitudes must not be treated as directly comparable to earlier native studies with different source/compiler binary hashes, run ordering, CPU frequency and idle/thermal conditions. The previous same-head producer-stripes study already excluded simply replacing the **shared** execution counter with per-*originating-producer* stripes as a solution; this study used `shared` to support continuity and did not redo that A/B.

## Engineering interpretation and next narrow discriminator

**Supported:**
1. **Both producers and workers** contribute substantially to additional CPU and voluntary switching per 30k Tasks as concurrent producers increase from 1 to 4/8; matched increment sizes are roughly comparable.
2. The *absolute* majority of switching belongs to workers, but the *incremental* overhead split is near even. Most CPU time likewise remains in the four workers at 4/8 producers, while the producers' share rises to 37–40%.
3. Four workers have similar CPU time; this is inconsistent with one grossly CPU-dominant worker monopolizing work, though not a fairness proof.
4. Whole-child nonproducer/nonworker residual stays bounded and positive, but cannot isolate GC, main or runtime sources.

**Not supported:** exclusive culpability of the outer admission mutex; the root of each worker voluntary context switch; the per-worker success/failure steal ratio; exact `Condition.wait` or `notify` impact without prior probes; funneled worker wake/park causality; any claimed speedup from a new queue, lock, coroutine, microtask or notification policy. The earlier intrusive inbox profile and negative `waiterAware` A/B remain separate findings and **must not be pooled** as exact-source evidence.

**Next carefully scoped research:** Map worker **work state** to the now quantified worker voluntary context switches without changing the Task fast path. Two possible bounded approaches, in research only:

- **Non-intrusive external observation** of worker thread identities and Linux scheduling/blocking state on a longer constant-source workload where the host permits sampling (e.g. `/proc/<pid>/task/<tid>/schedstat` plus appropriately controlled thread naming/identity), while preserving uninstrumented control. `schedstat` is an aggregate of running/waiting times, not futex attribution.
- Or a strictly opt-in worker-side counter family for **condition-wait enters/returns, empty wake searches, ingress batch successes, steal attempts/successes** combined with these thread-boundary resources. Use a separately compiled independent baseline to reveal observer effects. Prior worker parking instrumentation already exists; check whether it can answer the question without duplicating counters, and test the same full-victim source revision across all modes. **Do not invent another unrelated profiler until the existing counters are audited.**

Require a mechanism-specific, same-source uninstrumented performance A/B *and* shutdown/lifetime/lost-wakeup correctness gates before promoting any change. No change to `freshGc` default, `NotificationPolicy.always`, TaskRef GC roots, admission/backpressure, worker close/join or full-victim semantics. Grandfathered Draft PR #35 and Issue #20 remain open; `develop`, `main`, other workspace repositories untouched. No production contract is created by these resource snapshots.
