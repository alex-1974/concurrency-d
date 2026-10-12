# R0.5 XPS — Opt-in typed spare lookup diagnosis (2026-10-12)

**Decision:** **KEEP** `freshGc` as normal policy. **Do not prioritize** replacing the heterogeneous linear spare scan with a type-indexed cache based on these results: the five-round profile sees only about 1.4–2.0 dynamic casts per search and the probe-instrumented full scan/rearm timing is ~2–3% of instrumented admission mutex hold time. **DEFER** a cache redesign; investigate producer admission serialization, time under lock and result-handle/cell allocation with independent stage measurements before proposing an implementation. This is a research interpretation, **not a claim of established causality or a speed guarantee**.

## Source and original evidence

- Original, externally retained user archive: `r05-xps-recycle-lookup.tar.gz`; SHA-256 **`5f5b7de3eaca8aae5ed82a80ae773d94b19648fa4c3ad4efe3fdf430af7863de`**. Contains `raw.csv`, `pairs.csv`, `diagnostics.csv`, `summary.csv`, and `environment.txt`; original bytes are not rewritten or checked into repository history.
- **Measured research source HEAD:** `26872c9840f553ce9ad2460db1cc1c5102db5359` (confirmed via actual GitHub ref: this documentation commit is *after* the relevant `bf1cd2e` source instrumentation, `091c7c7` benchmark, `aa1351c` DUB config, `6558d55` driver and `eca1c2e` CI commits). Environment reported clean *tracked* working-tree status; `git status --untracked-files=no` does not rule out untracked files.
- Both program variants use `R05FullVictimSweep`, the same **complete N-slot, skip-self victim traversal** as the narrow production scheduler correction merged on `develop` in PR #37 (`7af4409a2e09a303dfbc6c54033d28c92eb67581`). R0.5 OwnedTask and M0 are **not** otherwise identical implementations.
- Native Dell XPS Intel i7-9750H, Linux 6.17.0-22 x86-64, **LDC 1.41.0**, LLVM 19.1.7, DUB 1.40.0; `powersave` governor; `lscpu` instantaneous CPU scaling 71%, not per-case clock average. No CPU affinity, thermal trace, or host-load control recorded.
- **120 isolated processes / 3.6 million total Tasks**: five rounds × three producer counts (1, 4, 8) × two budgets (8, 512) × `freshGc`/`recycleTyped` × `off`/`on`; four workers, 30,000 tasks/process, minimal mixed typed/GC-visible/void callable workload, shared atomic counter, release build.
- `off` = no lookup/admission timing; `on` = compile-time opt-in `R05RecycleLookupProbe` and **`submitObserved`** admission wait/hold histograms. Each mode has 30 distinct same-round GC/recycle pairs. Instrumented vs uninstrumented runtime differences cannot be interpreted as optimization gains or corrected by simply subtracting profiler overhead.

### Integrity checks repeated independently

`raw.csv` has 120 unique (round, producer, budget, profile, policy) keys, `pairs.csv` 60, `diagnostics.csv` 30 instrumented recycle rows, and `summary.csv` 12 grouped medians. All 120 reported exactly **30,000 completed** tasks; all `fresh_nodes+reused_nodes=30,000`, and all **1,765 typed handles** were observed per run. Each off-mode row omits lookup/admission fields, every on-mode GC row has all-zero lookup counters, and each on-mode recycler row satisfies `searches=30,000`, `hits+misses=30,000`, `hits=reused_nodes`, and `attempts=30,000+retention_full+ingress_full` with `yields=retention_full+ingress_full`. All reported pairs, diagnostic derived measures and summary values reconcile numerically to raw rows. No missing factor combinations or duplicate keys.

The measurement binary additionally checks exactly-once completion, typed results, GC-visible captures, void-task execution and complete drain. This is **not** a move-only/destructor safety test or a public `@safe` capture contract.

## Lookup cost and producer admission mutex

Medians over **five instrumented recycle runs per factor group**:

| Producers | Budget | Dynamic casts/search | Cache hit rate | Mean matched index (0-based) | Whole lookup ns/search | Lookup/hold diagnostic | Lock wait ns/attempt | Lock hold ns/attempt |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 8 | 1.680 | 96.44% | 0.680 | 128 | 1.95% | 91 | 6,784 |
| 1 | 512 | 1.362 | 98.27% | 0.385 | 127 | 2.10% | 92 | 6,413 |
| 4 | 8 | 1.779 | 92.70% | 0.750 | 186 | 2.28% | 29,603 | 7,931 |
| 4 | 512 | 1.802 | 98.13% | 0.830 | 221 | 2.82% | 24,990 | 6,786 |
| 8 | 8 | 1.781 | 92.43% | 0.747 | 206 | 2.31% | 77,038 | 8,819 |
| 8 | 512 | 1.956 | 98.06% | 0.985 | 191 | 2.86% | 58,905 | 6,862 |

Across the 30 profiled recycler cases, descriptive median **1.780 attempted casts per search**, **158.7 ns measured lookup per search**, and **2.295% for `lookup_ns/hold_ns`**. Over all 900,000 instrumented recycle tasks: **1,555,943 attempted casts**, **864,017 reused nodes** (96.00% of tasks), **35,983 new nodes**, and 7,800 empty-cache searches.

**Interpretation:** While some b512 runs reach `max_candidates=512`, the *actual examined* candidates average below 2. The fixed sequence of three callable layouts apparently finds a compatible node near the front often enough that scanning the whole capacity is not the usual path. This is a plausible explanation of why cache *capacity* does not translate into hundreds of RTTI checks. It is **not a proof** that dynamic casts are universally cheap on every task family or that heterogeneous workloads with more distinct layouts behave the same.

For 4/8 producers, average measured mutex **acquisition wait** climbs from ~90 ns with one producer to ~25–30 µs / ~59–77 µs, whereas instrumented hold time is ~6–9 µs and lookup time ~0.1–0.2 µs. This implicates **admission serialization and scheduling contention** as a more productive *next research target*, but waiting includes OS preemption and probe effects. No spin-wait, mutex replacement, lock-free queue or allocation relocation is warranted merely from this ratio.

**Caveats:** `lookup_ns` includes both clocks, counter increments, scan, cast and matched node rearm, not raw RTTI duration; `hold_ns` includes timed operations, GC allocations, retention bookkeeping, ingress and instrumentation and covers all attempts (including retries). Their ratio is **not** a causal percentage of end-to-end throughput, and total sampled wait time across producer threads may exceed process elapsed wall time.

## Paired throughput: off is the consumer-facing diagnostic

Five same-round ratios per factor group, recycle/GC. Each ratio uses two process-isolated samples of the **same codegen mode**, not an unpaired ratio of independent medians.

| Producers | Budget | **Off** ratio | Off wins /5 | **On** ratio | On wins /5 |
|---:|---:|---:|---:|---:|---:|
| 1 | 8 | 0.9138× | 1 | 0.8589× | 1 |
| 1 | 512 | **1.0859×** | 3 | 0.8686× | 0 |
| 4 | 8 | 0.9282× | 0 | 0.9611× | 1 |
| 4 | 512 | 0.9804× | 1 | 0.9951× | 2 |
| 8 | 8 | 0.9761× | 0 | 0.9334× | 0 |
| 8 | 512 | **1.0303×** | 4 | 0.9904× | 2 |

Pooled descriptive median of the **30 off** ratios **0.97844×** (9/30 recycle wins); for **30 on** ratios **0.95520×** (6/30 wins). This direction broadly agrees with the earlier **100k-task** full-victim archive's 0.96974× (7/30 wins), but its 30k samples, power/thermal state and profiler study are not directly interchangeable with that experiment. At p1/b512 and p8/b512, the off-mode recycling median **does** exceed one, so do not claim that every tested condition favors GC or that the storage trade-off is uniform.

Instrumented profiling is materially perturbing. For example, **p1/b512** switches from 1.0859× recycling/GC uninstrumented to 0.8686× instrumented, while the on/off slowdown depends on both policy and workload. This forbids interpreting raw `on` throughput as the proper absolute performance measure, treating on/off ratios as a clean profiler overhead subtraction, or assuming all 30 paired observations are independent hardware replicates.

## Memory and other limitations

**All 120 fresh-process `wait4` peak RSS readings are exactly 18,976 KiB**, regardless of mode, storage, producer count or budget. This data set has no RSS discriminatory power; it does **not** refute the earlier 100k-task full-victim experiment that observed lower recycled RSS (~18,548 KiB vs 22,280–25,348 KiB GC), and cannot establish a savings under the shorter workload. Do not promote a memory claim from this archive.

Producer-thread `GC.allocatedInCurrentThread` remains distinct from whole-process GC allocation; both policies still create per-task `ResultCell` and `TaskHandle`. The mixed workload shares one atomic execution counter and uses a bounded ingress, so producer scaling contains more than the cache lookup path.

## Decision and next discriminator

1. **KEEP `freshGc` default**: no consistent universal recycler-throughput win with fair uninstrumented matched samples.
2. **DEFER** replacing the linear cache scan with an indexed/typed cache as the immediate optimization: under this 3-layout workload, most searches take ~1–2 casts and account for only ~2–3% of **instrumented hold time**. No basis yet for predicting a large executor-wide gain.
3. Next controlled, opt-in experiment: partition **admission critical-section duration** into capacity/reaping, `ResultCell` + `TaskHandle` allocation, record creation/rearm, retention and publication. Preserve exactly the same rejection-before-allocation semantics, task lifetime, shutdown linearization and GC-visible roots. Report producer wait/hold and child CPU/context switches; pair with uninstrumented release builds. Stage timers **only in experimental specialization**, and do not equate instrumented time shares to uninstrumented cycle savings.
4. Independently qualify task-family lifetime/destructor/move-only behavior before considering memory-oriented optional typed recycling. The present data are not enough to redesign result/handle allocation or admit `@safe` cross-thread captures.
5. Preserve grandfathered research PR #35, Issue #20 and historic CSVs; **do not merge the research branch wholesale**, change `develop`, or edit other workspace repositories.

This resolves the immediate "is linear cache scanning the primary bottleneck?" discriminator negatively **for the measured mixed three-layout workload**, and redirects effort to **admission serialization and the allocation/publish critical section**, not an unproven indexed-cache rewrite.
