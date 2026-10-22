# P12 XPS native evidence review — 2026-10-13

**Status:** qualified **single-session native measurement evidence**, **NO-GO** for a permanent representation choice, public `@safe TaskScope`, or claimed C++ parity. The result is not a benchmark against `OwnedTaskExecutor`. No production source/CI/bench implementation is changed.

## Provenance and scope

- Original submitted source archive: `p12-xps-2026-10-13.tar.gz` (available with the research exchange, **not uploaded to this public repository** because its original manifest includes a local user path and hostname).
- **Full original archive SHA-256:** `2642bc92b2217abe218c21222a92602746670e19d8c8671563dbf3085497f33c`.
- [Derived unidentifying summary CSV](xps-2026-10-13-summary.csv) copies `summary.csv` from the supplied archive. It is **not a replacement for the 6 original per-sample CSVs**; the hash above identifies the original evidence.
- Source commit **`6ef0e9353359bbab6571a3f31eef83bcd1915ebb`** (detached worktree), original measured kernel [P12 matched pool](../concurrency/research/m1_matched_pool_benchmark.d).
- Host: Dell XPS 15, Intel **Core i7-9750H**, 6 physical cores / 12 logical CPUs, Ubuntu Linux x86-64, LDC **1.41.0** (LLVM 19.1.7), DUB **1.40.0**. `P12_CPUSET=none`; neither core pinning nor frequency/temperature/SMT control was recorded. `lscpu` snapshot reported CPU scaling 78%, **not** an in-run frequency trace.
- `--build=release`, same real M0 `SubmissionWorkerPool` + containers-d 0.2.0 for both arms; exactly the same 32-iteration integer kernel, TaskHeader/TaskRef, post-dispatch return markers, oracle/checksum and successful close/join.
- `stack`: private `BenchRecord[16_384]` on the stack. `heap`: private `new BenchRecord[16_384]` contiguous GC array. **Capacity is 16,384 records in both cases, even when only 2,048 tasks are submitted.** That choice is fair for a fixed-capacity buffer but magnifies constant heap allocation/setup costs for 2,048-task workloads.
- Six sequential workloads: 1, 2, 4 workers × 2,048 / 16,384 tasks, ingress 64. Each includes **3 excluded warm-up pairs and 11 measured pairs**, alternating stack-first / heap-first.
- Validated from all six raw-per-sample CSVs: **168 total rows**, 36 warm-up and 132 measured; **66 complete measured pairs**. No missing/duplicate pairs; all input counts/worker numbers/ingress/checksums agree within pairs. AB/BA ordering, exact time-partition sums, and all summary medians/min/max/order-statistic spreads were independently recomputed and matched the supplied summary. No sign of incomplete work; the binary's own worker-return/oracle checks are in the original source.

## Whole-batch release results (measured pairs only)

Absolute columns are the respective mode's independent **median of 11 totals**. The paired column is **median of (heap total − stack total)** on each corresponding pair; it need not equal the difference between the two individual medians.

| Workers | Tasks | Stack median ms | GC-array median ms | Paired heap−stack median ms | Pairs with stack faster |
|---:|---:|---:|---:|---:|---:|
| 1 | 2,048 | 0.725 | 0.841 | +0.068 | 8 / 11 |
| 1 | 16,384 | 4.725 | 4.844 | +0.006 | 6 / 11 |
| **2** | **2,048** | **0.628** | **0.834** | **+0.182** | **11 / 11** |
| **2** | **16,384** | **4.134** | **4.379** | **+0.291** | **11 / 11** |
| 4 | 2,048 | 0.988 | 1.160 | +0.225 | 11 / 11 |
| 4 | 16,384 | 6.903 | 7.001 | +0.382 | 6 / 11 |

**Interpretation:** Within this single XPS session, stack storage wins all eleven paired runs for both two-worker workloads and for the four-worker/2,048 workload. The 1-worker/16,384 and 4-worker/16,384 cases have **mixed signs and broad paired variation**: a positive median alone is not a stable win. Even where all 11 pairs agree, CPU-frequency stability, session replication, independence and uncontrolled host activity remain unqualified. Do not generalize to all machines or arbitrary task graphs.

### Where does the observed stack benefit arise?

The median **GC-minus-stack `prepare_ns`** difference ranges roughly **+137 to +148 µs** across six workloads. It is positive in **all 66 measured pairs**. Stack initialization usually takes roughly 10–28 µs; GC allocation and preparation usually takes roughly 146–174 µs. Some GC samples have much larger allocation/collection delays, and some 1-worker samples are unusually small.

Because the buffer capacity is **fixed at 16,384 slots**, that constant `new BenchRecord[16_384]` acquisition overhead is especially material for batches of only 2,048 tasks. It cannot be described as the cost of *one GC allocation per task*: P12 deliberately uses **one contiguous heap-array allocation per batch**, not the generic M0 `OwnedTaskExecutor`'s per-task nodes and result handles.

To isolate a conservative proxy for runtime *after* storage preparation, subtract `prepare_ns` from `total_ns` **within each individual pair**:

| Workers / tasks | Median paired total heap−stack | Median paired preparation heap−stack | Median paired **post-preparation** heap−stack |
|---|---:|---:|---:|
| 1 / 2,048 | +68 µs | +137 µs | **−46 µs** |
| 1 / 16,384 | +6 µs | +143 µs | **−18 µs** |
| 2 / 2,048 | +182 µs | +145 µs | **+18 µs** |
| 2 / 16,384 | +291 µs | +147 µs | **+57 µs** |
| 4 / 2,048 | +225 µs | +148 µs | **+50 µs** |
| 4 / 16,384 | +382 µs | +145 µs | **−58 µs** |

All numbers are **separately computed paired medians**, which do **not add algebraically**. Post-preparation includes worker startup, **overlapped** submission/execution/join and oracle verification; it does **not** isolate per-TaskRef dispatch, data locality, work stealing or scheduling.

**Decision supported:** stack record creation is frequently cheaper in this fixed-buffer microbenchmark. **Not supported:** claiming stack TaskRef dispatch is reliably faster than GC record dispatch, or that a borrowed TaskScope is faster than semantically different `OwnedTaskExecutor`.

### Worker count is the bigger performance question

For **stack records**, the observed median whole-batch times and effective end-to-end throughputs were:

| Tasks | 1 worker | 2 workers | 4 workers |
|---:|---:|---:|---:|
| 2,048 | 0.725 ms / 2.83 Mtasks/s | **0.628 ms / 3.26 Mtasks/s** | 0.988 ms / 2.07 Mtasks/s |
| 16,384 | 4.725 ms / 3.47 Mtasks/s | **4.134 ms / 3.96 Mtasks/s** | 6.903 ms / 2.37 Mtasks/s |

The two-worker setup was only **1.14–1.15× faster** than one worker with stack records. Four workers were approximately **1.57× slower** than two workers for 2,048 tasks and **1.67× slower** for 16,384 tasks. GC-array results also show degradation from two to four workers.

That is important **scaling evidence for this specific workload and one ordered experiment**, not evidence of a specific scheduler defect. Potential causes — synchronization/atomics, owner/thief contention, parking, overscheduling, task granularity, false sharing, SMT placement, CPU throttling, power state or OS noise — have **not been isolated or measured**. The six configurations were run sequentially, not permuted, so changing heat/clock/load over that session could bias apparent scaling. The 32-iteration task kernel is small; further kernel-size sensitivity is necessary.

### Noise/order checks

- At 1 worker / 16,384 tasks, median paired heap−stack was **−81 µs** for stack-first pairs but **+354 µs** for heap-first pairs.
- At 4 workers / 16,384 tasks, the same split was **−130 µs** (stack first) versus **+422 µs** (heap first).
- At 2 workers / 16,384 tasks, **both** order subsets favored stack (+271 and +310 µs median), and at 2 workers / 2,048 tasks both favored stack (+157 and +291 µs).
- The first two cases demonstrate that differences can be heavily order/time-sensitive; subgroup sample sizes are only 5 or 6. This is a **warning**, not a diagnosed AB/BA bias or proof of a specific thermal event.

## GO / NO-GO

**PASS (evidence integrity):** provenance, raw measurements, pair/order shape, identical inputs/results/checksums and measured phase sums are internally consistent with the benchmark source.

**KEEP (narrow finding):** one XPS run favors stack allocation of the fixed-size record buffer in many cases, especially both two-worker workloads. Storage preparation accounts for an important fraction of the observed total contrast. The real M0 worker-count scaling is weak beyond two workers under this short-task workload and merits focused investigation.

**DEFER:** permanent stack-versus-GC choice, public task ownership semantics, task-record placement optimization, performance regressions/thresholds, safe cancellation/failure behavior, D-vs-C++ performance and any general `@safe` promise. P12 does not measure `OwnedTaskExecutor` with equivalent contracts, native join failure handling, GC collections/finalizers, allocations per job, CPU PMU counters, worker idle/steal counts, or request latency in a long-lived pool.

## Recommended P13 research slices

1. **First isolate 4-worker regression on the real M0 pool** using a controlled CPU map (avoid treating SMT siblings as physical cores), randomized workload order and repeated independent sessions. Capture actual frequency/temperature/governor while executing. Vary kernel cost (e.g. 0/8/32/128/512 equivalent observed compute iterations), ingress size and worker count, with joined output checks always enabled.
2. **Decouple setup from dispatch** by reusing a long-lived worker pool and both kinds of prepared record arrays across many same-lifetime batches. Match post-dispatch return and ownership barriers, and only compare structurally equivalent tasks. Instrument full epoch lifecycle or isolate a header-thunk microkernel; do not label `submit_join_ns` as dispatch-only.
3. **Investigate allocation and codegen**: measure GC/allocator activity and memory footprint, inspect optimized LDC assembly for the header thunk and typed kernel, and use CPU counters (if permitted) to investigate cache lines, atomics/locks and steals.
4. Only after matching observable work and failure semantics, build an **owned-executor and C++ reference comparison**. Do not pay for missing guarantees by reporting faster timing.

**Branch decision:** retain P12 as qualified research evidence, do **not** merge/promote to `develop`, leave ADR-0001 PROPOSED / Issue #17 OPEN / Draft PR #38 DRAFT, preserve P01–P11 and grandfathered R0.5. No changes to production code follow from this single-session result.
