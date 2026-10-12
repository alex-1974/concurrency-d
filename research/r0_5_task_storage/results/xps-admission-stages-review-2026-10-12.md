# R0.5 — Dell XPS native admission-critical-section stage profile (2026-10-12)

**Research-only finding.** The **publish phase**, not typed-node creation or the linear spare search, is the largest measured portion of the **instrumented** producer admission mutex hold time in the full-victim mixed minimal workload. Growing producer concurrency coincides with sharply increased **mutex-acquisition wait**. **Do not infer** that `_pool.trySubmit()`, the inner mutex or condition-variable notification is individually proved responsible; the publish measurement aggregates multiple operations. **Keep `freshGc` as default and defer production architectural changes.**

## Exact uploaded evidence and reproducibility

- User-uploaded original archive: `r05-xps-admission-stages.tar.gz`; independently verified **SHA-256 `607dccfff4e1c40c268851ad7d1c71378f4735cfb034c1f81ff0be499f8532ce`**. Five original files: `raw.csv`, `pairs.csv`, `diagnostics.csv`, `summary.csv`, `environment.txt`. Original archive retained outside Git, unchanged.
- Recorded measured Git revision **`f65a02f28b1332ee9fa1d02bbe4bb485fa2b11ca`**, research `perf/r05-owned-task-pipeline`; tracked file status empty at measurement. This revision contains the stage instrument, benchmark, driver and [protocol](../r05-admission-stage-protocol.md). The experiment uses a research `R05FullVictimSweep` equivalent to the foreign-victim coverage merged on `develop` by PR #37 at `7af4409a2e09a303dfbc6c54033d28c92eb67581`. **R0.5 OwnedTask is otherwise a different executor from M0**.
- Dell XPS **Intel i7-9750H** (6 cores/12 threads), Linux 6.17.0-22-generic x86_64, glibc 2.43, **LDC 1.41.0** (DMD 2.111 frontend, LLVM 19.1.7), DUB 1.40.0, CPU governor **`powersave`**. One `lscpu` frequency-scaling snapshot **78%**, **not** an average clock while running. No controlled affinity, power trace, thermal conditions or background workload.
- Exactly **five rounds × three producer counts (1/4/8) × two retention budgets (8/512) × two policies (`freshGc`/`recycleTyped`) × two profiler modes (`off`/`on`) = 120 child processes**, **30,000 tasks each = 3.6 million completed tasks**; four workers, shared atomic execution counter, minimal alternating scalar/GC-visible wide/void callable mix.
- `off` uses uninstrumented `submit`; `on` uses the separate `R05AdmissionStageProbe`-versioned executable and existing `submitObserved` mutex wait/hold profiler. Each side uses the same full N-slot victim scan, task inputs, bounded inbox, retention and shutdown semantics. GC/recycle comparisons are paired **within** profiler mode and scenario; absolute `off` vs `on` timings are not an unbiased profiler-cost subtraction.

## Source and cross-file integrity audit

Independently read original CSVs from the archive and verified:

- `raw.csv`: **120** unique 5-factor keys, all scenarios present, `completed=tasks=30000`, `fresh_nodes+reused_nodes=30000`, and exactly **1,765** observed typed handles in each child;
- `pairs.csv`: **60** exact same-round same-scenario GC/recycle ratios, all recalculated from `raw.csv`;
- `diagnostics.csv`: **60** fully instrumented GC and recycling cases; each per-event stage mean and mutex wait/hold/retry average reconciles to the original cumulative counters;
- `summary.csv`: **12** groups with five paired rounds each, independently recomputed median ratios and recycling-win counts;
- All **60 `off`** rows omit admission and stage counters; every **`on`** case satisfies `accepted=30000`, `gate_count=attempts=accepted+retention_full+ingress_full`, `cell_count=node_count=publish_count=accepted=30000`, `yields=retention_full+ingress_full`. Every measured **`ingress_full=0`**; retention retries exist only rarely. Stage times and elapsed time are positive; each per-run sum of stage nanoseconds is smaller than cumulative mutex-hold nanoseconds.

The benchmark and CI enforce exactly-once accepted/completed, typed result checks and GC-visible callable behavior for this workload. **No new general `@safe`, move-only-destructor or closure-lifetime contract is established.** The only automatic cross-platform check on the instrumenter itself was small DMD 2.111 x86 / LDC 1.41 x86 and native ARM64 correctness, [CI #38250826838](https://github.com/alex-1974/concurrency-d/actions/runs/38250826838); CI has no reliable native throughput acceptance gate.

## Stage decomposition: the publication section dominates the *instrumented* admission hold

The table contains **medians over five profile-on GC/recycle cases** at the requested **four producers, budget 512**. Stage means divide that stage's total nanoseconds by stage event counts; mutex means divide total wait/hold by **all** admission attempts. These are different denominators if there are rejected attempts, although for this factor group retries were zero.

| Stage or lock metric | `freshGc` | `recycleTyped` |
|---|---:|---:|
| Gate: capacity / optional reap (ns/attempt) | **824** | **895** |
| Cell: fresh `ResultCell` and `TaskHandle` (ns/accepted task) | **824** | **782** |
| Node: fresh typed node or spare lookup/rearm (ns/accepted task) | **183** | **114** |
| **Publish: GC strong-root append + inbox `trySubmit` (ns/accepted task)** | **3,187** | **3,083** |
| Total admission mutex hold (ns/attempt) | **5,296** | **5,204** |
| Admission mutex acquisition wait (ns/attempt) | **18,945** | **17,784** |

Across all 60 profile-on rows, median ratios of stage cumulative time to admission mutex-hold cumulative time are **gate 17.25%**, **cell 14.81%**, **node 2.50%**, **publish 59.56%**. Median cumulative `sum(stages)/hold` is **94.16%** (individual ratios 93.02–94.66%). The residual consists of code not covered by stage brackets and instrumentation/clock accounting, **not** necessarily a true 5.8% uninstrumented overhead.

Publication accounts for **58.1–62.9%** of the probe-instrumented admission lock hold in the 60 cases; the next-highest stage is gate or cell. The measured node-creation/recycle section is only ~2–3% of the observed admission mutex hold in typical cases. **Do not translate these fractions directly to production execution cost or promises of speedup.** Timing calls, result allocation/GC interruptions, scheduling inside the lock and the instrumentation may change the hot path.

The timed **publish** stage contains:
```d
_retained ~= RetainedTask(node, node.returnedFlag());
const status = _pool.trySubmit(node.reference());
```
Inspecting the exact research source reveals `_pool.trySubmit()` calls `_inbox.trySubmit()`, which **acquires a second (inbox) mutex**, checks closed/capacity, updates slots and generation and **calls the condition-variable notification** in the `always` policy used here. Consequently the measured publishing time combines at least array growth/root bookkeeping, nested mutex acquisition, inbox enqueue accounting and possible notification. **It is not evidence that notify or the second lock independently takes 3 µs.** This identifies the **next measurement boundary**, not a license to remove synchronization or bypass the generation/wake predicate.

## Producer count and admission contention

Median over **all 20 profiled policy × budget × round samples per producer-count** (these combine heterogeneous factors, so are descriptive, not a single controlled pair):

| Producers | Admission wait ns/attempt | Hold ns/attempt | Publish ns/accepted task |
|---:|---:|---:|---:|
| **1** | **50** | **3,949** | **2,388** |
| **4** | **18,707** | **5,318** | **3,192** |
| **8** | **45,222** | **5,552** | **3,302** |

**Admission acquisition wait rises far faster than measured hold time.** For 4 producers its group medians are ~18 µs versus ~5 µs hold; for 8 producers ~45 µs versus ~5.5 µs hold. The **log2-binned wait p95 upper bound** is 127 ns for 1 producer, **131,071 ns** for 4 and **524,287 ns** for 8 (across both storage policies and budgets); these are **upper bounds of broad histogram buckets, not precise p95 latency**.

No one can conclude from this data alone whether source of latency is mutex contention, OS scheduling/preemption, GC pauses, nested lock effects or the shared task execution counter. Both the profiled mutex waits and benchmark's atomic workload influence overall producer scaling. The near-zero `ingress_full` and small number of retention retries show that **under this 30k minimal workload** queue-full retry is not the main explanation.

## Native throughput: uninstrumented results carry the storage decision

Each ratio is the **median of five paired `recycleTyped/freshGc` throughput ratios** for identical factor settings; do not compute ratios of independent median rates or compare `on` to `off` as a performance optimization.

| Producers | Budget | **Uninstrumented** recycling/GC | Recycling wins /5 | Profiled recycling/GC | Profiled wins /5 |
|---:|---:|---:|---:|---:|---:|
| 1 | 8 | **0.8092×** | 2 | 1.0634× | 4 |
| 1 | 512 | 1.0640× | 3 | 1.0115× | 3 |
| 4 | 8 | **0.9351×** | 1 | 0.9916× | 0 |
| 4 | 512 | **0.9965×** | 1 | 1.0189× | 3 |
| 8 | 8 | **0.9745×** | 0 | 0.9886× | 1 |
| 8 | 512 | 1.0159× | 3 | 1.0240× | 3 |

Across 30 uninstrumented paired ratios, pooled descriptive median **0.99195×**, recycling wins **10/30**; among 30 profiled ratios median **0.99689×**, recycling wins **14/30**. These are heterogeneous groups on one machine and are **not** an independent 30-trial population test. At one producer/budget8 uninstrumented paired ratios swing **0.731–1.468×**: environment and small-sample drift remain substantial. The earlier full-victim **100k-task** native mixed study observed 0.96974× (7/30 wins), and the **30k-task** typed spare-lookup study 0.97844× (9/30 wins). **Different campaigns and sources are not directly poolable.** Present evidence still does **not** justify adopting `recycleTyped` as the generally faster policy.

The GC/recycling `wait4` process RSS is not distinguishable here: **119/120** child processes report **18,792 KiB**, the remaining one **18,664 KiB**; at 30k tasks this is likely a high-water/process-floor limitation, not proof that recycling never saves resident memory. Producer-thread GC-allocation bytes are not total-process allocations.

## Engineering disposition and next narrow experiment

**KEEP** `freshGc` as normal/default storage, experimental typed recycling in grandfathered Draft PR #35, existing semantics of `TaskHandle` and GC roots, ingress admission boundedness, and corrected full-victim scheduler. **DO NOT** merge R0.5 history wholesale, add a lock-free queue, or move allocation out of the critical section based on a timing fraction.

**Next single mechanism discriminator:** split the research-only **publish bracket** into
1. `_retained ~= RetainedTask(...)` (strong root and D dynamic-array bookkeeping);
2. `_pool.trySubmit(node.reference())` (nested inbox lock, queue update and condition notification).

A second iteration may further distinguish inbox-lock wait, the enqueue operation, and `Condition.notify` **only if** the first split proves publish/queue costs dominate in controlled native results. In each case use compile-time opt-in measurement, avoid changing mutex lock order, avoid changing task ownership or wake-generation semantics, and keep uninstrumented same-workload GC/recycle evidence. Record CPU governor, frequency limitations, process CPU/context switches and task correctness.

**No production promotion:** existing provenance, research PR #35 Draft and Issue #20 open. `develop` remains untouched; no release or edits to other workspace repositories. The present finding prioritizes measuring the nested admission→inbox publication path, but **does not prove an architectural replacement will improve throughput**.
