# R0.5 — Dell XPS uninstrumented CPU and scheduling qualification (2026-10-12)

**Disposition: KEEP `freshGc`, `NotificationPolicy.always`, the complete foreign-victim scan, bounded admission and the existing locking/wake contracts.** The unchanged full-victim R0.5 release consumer shows **negative throughput scaling as the number of producers rises from one to four/eight**, accompanied by substantially higher process CPU use and voluntary context switching per completed task. This supports **further discriminating experiments**, not a causal claim that futexes, notifications, the outer admission mutex, GC or a particular worker is independently responsible. Hardware `perf stat` was **denied** by the host and supplied no event/cycle/instruction/futex data.

## Original source and archive

- Uploaded archive **`r05-xps-native-system.tar.gz`**, SHA-256 **`289011eb23984b72ec56b7f059dccb67b23a8e6542fafb2bdb1b49422e0391d8`**. The original contains precisely four regular files in `r05-xps-native-system/`: `raw.csv`, `pairs.csv`, `summary.csv`, `environment.txt`. The original artifact is **retained separately**, not rewritten or merged into Git history.
- Measured research HEAD **`92ab6fb7f69cb9436657072df18986bc4f333340`** on grandfathered `perf/r05-owned-task-pipeline`, `build_config=task-pipeline-mixed-full-victim-sweep`; binary SHA-256 **`a641dbe3d127bfee57df7a7e44b12db7963682ca93b2633f90450ec5656b0558`**. The named research source/driver at that exact SHA exists in Git. The recorded tracked worktree status is empty; the check did not include untracked files. Do not attribute these results to later report-only commits.
- `compiled_versions=R05FullVictimSweep only`, **`instrumentation=off; parking=off; notify=always`**, `counter=shared`. No stage, inbox, admission, parking, task trace or other stopwatch in this consumer hot path. Storage policies `gc` and `recycle` are **identical-codegen-mode, fresh-process** comparisons. The full N-position victim search reflects the narrow correction merged into `develop` at `7af4409a2e09a303dfbc6c54033d28c92eb67581` (PR #37), but the **research OwnedTask implementation is not the production M0 executor**.
- Linux **6.17.0-22-generic x86-64**, Dell XPS Intel **Core i7-9750H** (6 cores / 12 threads), LDC **1.41.0**, LLVM **19.1.7**, DMD frontend **2.111.0**, DUB **1.40.0**, CPU governor **`powersave`**. One `lscpu` instantaneous CPU scaling snapshot was **61%**; it is **not** a measure of average frequency for any run. No controlled CPU affinity, thermals, AC-power state, background load or per-worker stack trace was recorded.
- The runner selected 4 workers, 30,000 tasks/process, one/4/8 producers, budget512, five rounds, storage `gc` and `recycle`, and two **distinct minimal and compute-1024 workloads**, with a **shared** execution counter. Total **60 independent child processes**, **1,800,000 completed tasks**, **30 same-round storage pairs**, **six factor-group summaries**. The compute 1024-round deterministic checksums agree between policies and producer counts; the minimal counter checksum is zero by definition.

## Independent cross-file integrity audit

Parsed the archived CSVs afresh and checked:

- Exactly **60 unique** (round, workload, producers, budget, policy) raw case keys and all expected combinations. Every case reports **30,000 completed tasks**, 1,765 observed typed result handles, `fresh_nodes+reused_nodes=30,000`, expected worker/budget/mode/counter labels, positive throughput, and the appropriate workload/checksum. All per-child CPU/switch/GC metrics are nonnegative; no major faults reported.
- Exactly **30** same-round pairs. Recalculated every `recycle_over_gc` from the two raw throughputs, checked its associated throughput, child voluntary context switches and user CPU copies, and verified all six grouped five-round median ratios and recycle-win counts.
- The per-child external wall time is no shorter than the benchmark's internal timed interval, as expected. Producer-thread CPU sums are bounded by reported whole-child CPU. **`wait4` here waits for the benchmark child itself**, so child CPU/system and voluntary/involuntary context-switch counts include all its worker, producer and other process threads. The separate `resource` record is producer-thread-only; subtraction of producer from whole child is a residual, **not a verified worker-only event count**.

**Available profiling:** `perf_mode=try` and `perf_available=False`. The preflight to `perf stat` on `/bin/true` was refused, reporting no supported events and `/proc/sys/kernel/perf_event_paranoid=4`. **There is no `perf.csv` or `perf-raw/` folder; zero perf-wrapped benchmark samples were collected.** No sudo/sysctl/security change was attempted. Hence there is **no direct evidence** for hardware cycles/instructions, futex syscall numbers, kernel call stacks, exact wakeup-to-run times, per-thread blocked states or notification usefulness. The fully valid **`wait4` whole-process results remain available**, however.

## A. Actual throughput: producer count is negatively associated with rate

Independent median uninstrumented **tasks/s** over five separate runs in each group:

| Workload | Producers | `freshGc` tasks/s | `recycleTyped` tasks/s |
|---|---:|---:|---:|
| minimal | **1** | **243,991** | **363,877** |
| minimal | **4** | **203,167** | **198,413** |
| minimal | **8** | **194,369** | **194,868** |
| compute-1024 | **1** | **408,599** | **404,775** |
| compute-1024 | **4** | **233,383** | **251,652** |
| compute-1024 | **8** | **228,899** | **228,219** |

For the compute workload, the GC independent median falls **~44%** from 408.6k at one producer to 228.9k tasks/s at eight producers; the recycling independent median falls **~44%** from 404.8k to 228.2k. Despite more producer threads, there are still only four workers, and many additional producer interactions can increase scheduling/locking without increasing worker execution capacity. **This is evidence of negative end-to-end producer scaling on the present implementation**, not proof that one mutex is solely responsible.

Same-*round* ratios of the throughput with 4/8 producers to one producer, for each storage policy:
- minimal GC: median **0.852× (4/1)**, **0.797× (8/1)**; minimal recycle: **0.571×**, **0.536×**;
- compute GC: **0.582×**, **0.559×**; compute recycle: **0.617×**, **0.585×**.

The one-producer **minimal** rates drift dramatically across rounds (fresh GC ~226–379k; recycle ~237–377k). Thus the exact magnitude of minimal p1 scaling and apparent independent-median storage differences are particularly unstable. Do not treat the six factor groups as a large randomized inference sample. Compute scaling is much more directionally consistent.

## B. CPU time and context switches rise sharply with producers

These medians pool **10 independent child processes** in each (workload, producers) group (**5 GC plus 5 recycle**). This pooling is *descriptive* and does not replace matched GC/recycle comparisons or establish a causal mechanism.

| Workload | Producers | Process CPU seconds per 30k Tasks | Voluntary switches / child | Voluntary switches / task | CPU equivalents, child CPU/external wall | System CPU fraction |
|---|---:|---:|---:|---:|---:|---:|
| minimal | **1** | **0.311 s** | **37,262** | **1.242** | **3.23×** | **50.0%** |
| minimal | **4** | **0.533 s** | **79,229** | **2.641** | **3.50×** | **53.9%** |
| minimal | **8** | **0.559 s** | **80,920** | **2.697** | **3.56×** | **54.4%** |
| compute-1024 | **1** | **0.285 s** | **20,193** | **0.673** | **2.91×** | **32.6%** |
| compute-1024 | **4** | **0.513 s** | **60,113** | **2.004** | **3.47×** | **41.9%** |
| compute-1024 | **8** | **0.552 s** | **63,467** | **2.116** | **3.52×** | **42.3%** |

Whole-process CPU seconds are summed user + system usage across producer and worker threads; they are **not elapsed wall seconds**. The CPU-equivalent column is a *ratio* of total child CPU to elapsed external wall time (e.g. 3.5 means roughly 3.5 logical CPUs worth of CPU time averaged over that duration), **not measured pinned-core utilization**. The workload can accumulate more CPU seconds than wall seconds because threads run concurrently.

Compared with one producer, four/eight producers consume **~1.7–1.9× more total CPU per 30k tasks** in these pooled groups. Voluntary context switches jump from **~1.24 to ~2.64–2.70 per task** for minimal and **~0.67 to ~2.00–2.12 per task** for compute-1024. Involuntary context switches remain much fewer (typically single digits per child), and the process peak RSS is exactly **24,744 KiB** in **every** case (high-water/measurement floor, no memory-policy separation possible).

Producer-only median voluntary switches, for context:

| Workload | Producers | Producer voluntary switches / child | Whole-child voluntary switches / child |
|---|---:|---:|---:|
| minimal | 1 | **3,412** | **37,262** |
| minimal | 4 | **26,322** | **79,229** |
| minimal | 8 | **26,747** | **80,920** |
| compute-1024 | 1 | **2,632** | **20,193** |
| compute-1024 | 4 | **22,888** | **60,113** |
| compute-1024 | 8 | **23,461** | **63,467** |

**Interpretation boundary:** Many voluntary context switches are outside the producer threads, so worker/other-thread behavior materially contributes to the process total. A context switch may arise from waits, condition variables, scheduler yield, locks or unrelated library behavior; neither `wait4` nor `getrusage` establishes *which syscall or which synchronization object* caused it. The previous stopwatch data that showed expensive outer admission waits and notifications are **consistent** with this pattern but are not independently validated causal proof by this archive.

## C. Storage-policy comparisons remain heterogeneous and uncertain

Medians are **within-round, same-workload, same-budget `recycleTyped/freshGc` ratios**, not ratios of independent median rates.

| Workload | Producers | Paired median recycle/GC | Recycle wins / 5 | Five-pair min–max |
|---|---:|---:|---:|---:|
| minimal | **1** | **0.97293×** | 2 | **0.795–1.672×** |
| minimal | **4** | **1.00168×** | 3 | **0.886–1.036×** |
| minimal | **8** | **1.00948×** | 5 | **1.003–1.066×** |
| compute-1024 | **1** | **1.01481×** | 3 | **0.871–1.111×** |
| compute-1024 | **4** | **1.07647×** | 4 | **0.940–1.205×** |
| compute-1024 | **8** | **0.98611×** | 2 | **0.905–1.064×** |

Descriptively, across all **30 heterogeneous paired ratios** the median is **1.00945×**, with recycling winning **19/30**. This is **not** a statistically justified universal speed claim. Notably compute 4-producer recycling has median ~+7.6% but one loss and substantial variation (0.94–1.21×); the pattern does **not** persist at eight producers. Minimal p1 exhibits very large within-round ratio variation (0.795–1.672×), **so its paired median 0.973× and independent median throughputs give very different impressions**; only ratios of matched runs support a paired comparison.

Fresh GC creates 30,000 nodes per process. Recycler median new-node counts are ~515–588 depending on workload/producers, meaning >98% of concrete nodes are reused at budget512. Producer-only GC allocations remain close to ~12.2–12.3 MB per run (fresh result cells/handles continue in both policies). All 60 process peak RSS observations are the same 24,744 KiB. **Do not** equate reuse with 98% total GC-allocation savings or infer a general memory improvement from this fixed-RSS corpus.

## D. What this does and does not resolve

**Supported with native uninstrumented data:**
- Increasing producers from one to four/eight strongly correlates with **lower task throughput, higher whole-process CPU seconds/task, more voluntary switches/task**, and higher observed system CPU share in both tested workloads.
- Whole-child context-switch counts substantially exceed producer-thread-only counts, so any follow-up needs to consider workers as well as outer admission.
- The current GC-vs-recycle comparison is not uniformly in either policy's favor; neither `recycleTyped` general promotion nor replacing `freshGc` is justified.
- `perf` hardware/kernel events were **not** collected because access was refused. The absence of those counters is an explicit negative capability finding, **not** a missing required correctness gate.

**Not established:** futex syscall count; exact `Condition.notify()` CPU cost in the unprofiled executable; wake-to-run p95/p99, owner-worker breakdown, sleeping-waiter share, lock-hold causality, intrinsic compiler-vs-C++ speed, or prediction of speedup from any new synchronization scheme. The older XPS waiter-aware A/B already found no consistent improvement and used **different code and benchmark settings**, so do not pool it with this report's plain results.

## Decision and next precise experiment

1. **KEEP** production/default `freshGc`, `NotificationPolicy.always`, strong GC-root-before-inbox publication, correct full victim traversal, bounded admission and both original mutex/generation semantics. No production or consumer API change; no broad research merge.
2. **DEFER** typed recycling promotion, indexed spare-cache rewrite, notification suppression, replacing the inbox with lock-free structure, or moving allocations outside admission. The present evidence has strong scaling/scheduling symptoms but **not a uniquely isolated cause**.
3. **Highest-value next control:** repeat a *matched same-source, same-compiler native* matrix contrasting the benchmark's existing **`shared` vs `striped` execution-counter** setting (1/4/8 producers, minimal and compute-1024, both GC and recycle or GC as the initial control). This is a **benchmark-confounder discriminator, not a scheduler rewrite**: a shared execution atomic can itself cause cache-line bouncing and apparent worker contention. The old notification A/B used a striped counter and is not comparable directly to the present shared-counter campaign. Use uninstrumented same binary, alternating counter-mode order, exact task checksums and paired within-round throughput/child-context-switch comparisons.
4. If negative scaling persists with the striped counter, gather a narrower external *thread-aware* scheduling profile where permitted (e.g. per-thread `/proc/<pid>/task/*/schedstat` or passive sampling, with caveats and without lowering host security). CPU/voluntary switch counters on their own cannot identify lock/futex mechanisms; any proposed notification variant needs an exact-source paired throughput **and low-arrival wake-tail gate**, not simply cheaper measured `notify` calls.
5. Preserve the original artifact, all pre-PR37 results and the grandfathered research branch. Keep Draft PR #35 and Issue #20 open; `develop` remains at `7af4409a2e09a303dfbc6c54033d28c92eb67581`. No tags, release or writes to other repositories.

**Review status:** source-pinned, full evidence independently cross-checked, **qualifies the specific uninstrumented negative-producer-scaling observation**, but does **not** yet qualify an architectural optimization.
