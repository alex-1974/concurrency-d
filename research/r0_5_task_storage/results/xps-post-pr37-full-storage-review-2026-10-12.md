# R0.5 XPS — GC-fresh vs typed recycling with full victim coverage (2026-10-12)

**Status: native research finding. Decision: KEEP `freshGc` as normal default; REJECT promotion of the *current* `recycleTyped` implementation as a general throughput optimization; DEFER a separately qualified, type-specialized cache and task-family-specific memory policy.** Issue [#20](https://github.com/alex-1974/concurrency-d/issues/20) remains open; grandfathered Draft [PR #35](https://github.com/alex-1974/concurrency-d/pull/35) is not a production merge candidate.

## Original evidence, provenance and correctness

- Original user-uploaded archive: `r05-post-pr37-full-storage.tar.gz`; verified **SHA-256 `9a4567a8fe1b313f090a495f33bf0ac40a0acbde0d5e37436c576c8292c6dc49`**. Three unmodified original files: `raw.csv`, `summary.csv`, `environment.txt` (outside repository Git history).
- Measured grandfathered research HEAD: **`9f461204f62365e0dcefbf78a1d6635d0daccfac`**, with no tracked working-tree changes reported in the benchmark environment. Relevant accepted production full-victim fix on `develop`: **`7af4409a2e09a303dfbc6c54033d28c92eb67581`**. The latter is a reference to the equivalent victim-search mechanism, **not** the benchmark executable under test.
- Scheduler selected in all rows: `victim_sweep=full` / `task-pipeline-mixed-full-victim-sweep`. Both storage policies use that same built binary, full N-slot foreign-victim search, 4 workers, the same bounded inbox, task inputs, typed-handle/result/exception semantics, and batch8. This does **not** make R0.5 equivalent to M0's complete implementation.
- Linux x86-64 6.17.0-22-generic, glibc 2.43, Dell XPS i7-9750H (6C/12T), compiler reported as **`ldc2`** in this archive. **The exact compiler version is not printed in this run's environment file**; prior sessions on the same machine reported LDC 1.41.0, but do not treat that as independently reverified here. `lscpu` had an 89% CPU-scaling snapshot; **governor, sustained clocks, power, thermals, affinity and host load are not recorded**, so small causal speed claims are inappropriate.
- Matrix: **5 paired rounds × 3 producer counts (1/4/8) × 2 retention budgets (8/512) × 2 policies (GC/recycle) = 60 isolated Linux processes and 6,000,000 completed tasks**, 100,000 tasks each. Exactly 30 unique policy pairs, 5 per group; GC/recycle order alternates every round. Every accepted/completed record reports 100,000 and `fresh_nodes + reused_nodes = 100,000`; all 60 runs report 5,883 real `TaskHandle` observations; no missing data or duplicated scenario/round/policy keys. Verified each submitted `summary.csv` group ratio against its five raw policy pairs.
- Workload: `multi_producer.d` default **minimal**, not the `compute-1024` variant. Tasks cycle through small typed, GC-visible 256-byte-payload typed and void callables, sharing an atomic execution counter. The benchmark asserts accepted/completed/executed counts, correct observed typed results and drained records. Its timing includes worker/producers, submission and admission waits, observed handles, close/join, but **excludes** its later full `GC.collect()`. It is **not** a pure allocator microbenchmark or an arbitrary move-only-capture lifetime qualification.

## End-to-end throughput: recycling is slower across every grouped median

Each paired ratio below is `recycleTyped.throughput_per_s / freshGc.throughput_per_s` **within the same round**. Values in GC/recycle throughput columns are independent medians, **not** the numerator and denominator of the paired ratio.

| Producers | Budget | Median GC tasks/s | Median recycle tasks/s | Paired recycle/GC | Recycle wins /5 | Pair range |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 8 | 339,121 | 327,157 | **0.9647×** | 1 | 0.916–1.057× |
| 1 | 512 | 347,111 | 318,368 | **0.9789×** | 2 | 0.871–1.242× |
| 4 | 8 | 187,514 | 180,852 | **0.9642×** | 1 | 0.950–1.004× |
| 4 | 512 | 189,724 | 187,865 | **0.9684×** | 1 | 0.957–1.014× |
| 8 | 8 | 177,345 | 174,931 | **0.9864×** | 2 | 0.958–1.025× |
| 8 | 512 | 194,296 | 187,287 | **0.9762×** | 0 | 0.909–0.989× |

Across all **30** same-round, same-producer/budget ratios, descriptive median **0.96974×**, recycling wins **7/30** and fresh GC wins **23/30**. Because the groups have different loads and share a single experimental machine, this pooled median and sign count are *descriptive*, **not** a population-wide speed ratio or an independent 30-trial hypothesis test. There are only **five repeats per factor group**. Note the substantial single-producer/512 dispersion, including an isolated 1.242× recycling win.

**Producer scaling is poor for BOTH policies in this minimal task workload.** At budget512 independent median throughputs for GC 1/4/8 producers are ~347k/190k/194k tasks/s, versus recycling ~318k/188k/187k. Cross-producer medians are not paired comparable timings, but together with earlier R0.5 instrumentation they motivate profiling admission mutex/producer waiting and benchmark atomic contention; do not assign cause from this storage study alone. The separate M0 `compute-1024` native test cannot be compared as if it were the same workload.

## Node reuse versus actual GC allocation

Every fresh-GC run creates exactly **100,000** concrete task nodes. Median node counts in the recycling policy:

| Producers | Budget | New nodes | Reused nodes | Reused share |
|---:|---:|---:|---:|---:|
| 1 | 8 | 3,728 | 96,272 | 96.27% |
| 1 | 512 | 524 | 99,476 | 99.48% |
| 4 | 8 | 7,111 | 92,889 | 92.89% |
| 4 | 512 | 665 | 99,335 | 99.34% |
| 8 | 8 | 7,501 | 92,499 | 92.50% |
| 8 | 512 | 750 | 99,250 | 99.25% |

**This is reduction in concrete-node creations, not total allocations.** Every submission still allocates a fresh `ResultCell` and `TaskHandle`. The `producer_gc_bytes` metric counts **only allocating producer threads** and is not whole-process GC allocation. For four producers:
- Budget8 median **39,999,664 → 38,995,120 B** (saved **1.005 MB**, **2.51%**).
- Budget512 median **41,042,464 → 40,886,272 B** (saved **0.156 MB**, **0.38%**).
All 30 paired producer-byte differences favor recycling, but the reduction is far smaller than the percentage of reused nodes.

## Resident memory and GC-used-size deltas

`peak_rss_kib` is **per-isolated-process `wait4` ru_maxrss**, not a continuing parent's cumulative peak. Independent median GC versus recycle peak RSS:

| Producers | Budget | GC peak KiB | Recycle peak KiB | Difference MiB |
|---:|---:|---:|---:|---:|
| 1 | 8 | 22,752 | 18,548 | −4.11 |
| 1 | 512 | 25,348 | 18,548 | −6.64 |
| 4 | 8 | 22,280 | 18,548 | −3.64 |
| 4 | 512 | 25,084 | 18,548 | −6.38 |
| 8 | 8 | 22,460 | 18,548 | −3.82 |
| 8 | 512 | 25,112 | 18,548 | −6.41 |

29 of 30 same-round pairs favor recycling on RSS; **one pair ties**. All **30 recycling peak values are exactly 18,548 KiB**: likely a process/measurement floor or stable high-water mark and a **limitation to interpretation**, not justification for extrapolating a fixed MiB saving to larger tasks or unrelated applications. RSS includes D runtime, stacks and GC heap; no allocation-site attribution is available.

The separate `GC.stats().usedSize` **after close, before explicit collection** also favors recycling in all 30 pairs: GC deltas have group medians ~11.5–14.6 MiB versus recycle ~0.7–6.0 MiB. The **after-collection** used-size delta is ~1.3 MiB GC versus ~0.2–0.4 MiB recycle. These are changing process-heap used-size deltas, **not** cumulative allocation, retained peak, proof of no leaks or destructor safety.

## Mechanism hypotheses and next engineering decision

Source inspection of `OwnedTaskExecutor.trySubmitImpl` at the measured research head shows:
1. Both policies create a fresh `ResultCell!R` and `TaskHandle!R` for every accepted task, while holding the producer-side admission mutex.
2. `recycleTyped` scans `_spare` **linearly under that mutex**, using a dynamic `cast(OwnedNode!(F,R))` to match exact concrete type; then re-arms the selected node. `reapCompletedUnderLock` additionally manages strong-root `_retained` and `_spare` arrays.
3. Those lookups, casts, writes, GC allocation cost and producer contention are **plausible countervailing costs**, **not isolated or directly measured causes**. The observed 92–99% reduction in node allocations with ~3% lower throughput is consistent with their potential importance but does not assign per-operation cost.
4. Increasing `budget` changes retention/backpressure and reuse hit rates; it is not a pure cache-lookup-size experiment. No end-to-end causal attribution should be made from budget8/512 comparison alone.

**KEEP:** `freshGc` as the existing normal/default implementation, its result-handle/lifetime semantics, and the production full-victim fix already merged as PR #37.  
**REJECT NOW:** promoting **this** dynamically cast, heterogeneous spare-cache policy as a *universal performance optimization*. It has a consistent adverse throughput tendency on the long native mixed minimal workload despite memory wins.  
**DEFER/RESEARCH:** a narrow compile-time-typed or indexed spare-cache lookup **only if** independent profiling shows type-match/lock time is material; qualify equivalent GC-visible captures, `void` and typed handles, exception paths, post-dispatch lifetime, move-only/destructor cases, peak RSS and full pipeline throughput. A memory-oriented optional policy may be relevant for constrained task families, but must be explicitly justified against lower throughput, not assumed generally optimal.

**No production promotion from these results:** PR #35 remains Draft; Issue #20 remains open. Historic pre-PR37 CSVs and commits are preserved, not relabeled. `develop` and all other repositories remain untouched. The source-backed victim search is only one shared scheduling mechanism, not an assertion of whole-executor semantic identity.

### Suggested next discriminator

Before another structural rewrite, instrument (opt-in and outside standard throughput timing) **number of spare entries examined**, dynamic-cast match index/hit distribution, per-admission lock hold/wait and producer retries; compare `full` GC/recycle on the same XPS using uninstrumented paired binaries as control. Alternatively, use a small separate pure lookup kernel at the same type mix to bound only the RTTI-search cost, **never as sole production evidence**. Keep historical storage results as the baseline and do not rewrite PR #35 wholesale.
