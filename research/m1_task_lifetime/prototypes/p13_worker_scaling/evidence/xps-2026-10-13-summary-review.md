# P13 — Three-session XPS summary review (2026-10-13)

**Disposition:** Qualified as an internally consistent *summary-level* dataset, not as fully audited raw benchmark evidence. **KEEP** the workload-granularity/scaling observation; **DEFER** scheduler changes, a public `@safe` task policy, and C++ performance claims.

## Source and provenance

- **Provided input:** `summary.csv` uploaded in the P13 research exchange on 2026-10-13. Only this summary file, **not** the original P13 native archive, manifest, individual `csv/session*.csv`, raw DUB logs, thermal/frequency readings, CPU affinity mask or seeds, was supplied in this turn.
- **SHA-256 of uploaded `summary.csv`:** `b5da24cb95adab3bcc06a23c741bb38ac9efcf5b0ec3d430d5de42ff4e3171dc`. Source data remain in the conversation upload; we have **not** published the full file or local host identifiers into this public repository.
- **Source code reference:** [P13 research kernel/runner](../README.md). It is designed to run the unchanged M0 SubmissionWorkerPool and containers-d 0.2.0 with 1/2/4 workers, separate record-array preparation/pool startup/actual wave work/close+join stages, and an exact oracle with `ulong` checksum. **The uploaded summary alone does not verify the compiler, release flags, hardware, git SHA, affinity or process run order; those require `manifest.txt` and raw CSVs.**
- The input has **135 rows**, exactly all combinations of **3 named sessions × 5 compute sizes (0/8/32/128/512 unsigned iterations per task) × 3 inbox capacities (8/64/256) × 3 worker counts (1/2/4)**. Each reports **7 samples**, **2,048 jobs per wave**, **3 waves**, a median/minimum/maximum `waves_ns`, median pool startup, median `parkCount` and retries, and the checksum.
- Thus the summary describes **945 measured configuration occurrences** (plus warm-ups not included in `summary.csv`), not 945 raw observed durations that can individually be reanalyzed. We confirmed no missing or duplicate configuration rows, valid nonnegative counters/durations, min ≤ median ≤ max, fixed tasks/waves, and an identical checksum for each compute size across sessions/worker counts/ingress. **These are internal summary checks, not independent checks of the task-level result oracle, raw wave order or CPU clock state.**

## Scaling result — robust workload-size crossover, not a diagnosed mechanism

For each named session, compute size and inbox capacity, the table below divides the **seven-sample median wave duration for 4 workers** by the **corresponding median for 2 workers**. Within each compute-size row, the headline ratio is the median of **9 ratios = 3 sessions × 3 inbox capacities**. This is a **ratio of separate config medians, not the median of paired differences/ratios within the original randomized sweep** (raw session CSV required).

| Iterations/task | Median 4w/2w duration | Cases where 4 workers faster | Median 2w/1w duration | Cases where 2 workers faster |
|---:|---:|---:|---:|---:|
| 0 | **1.676×** | **0/9** | 1.028× | 2/9 |
| 8 | **1.620×** | **0/9** | 1.037× | 3/9 |
| 32 | **1.349×** | **0/9** | 1.035× | 2/9 |
| 128 | **1.167×** | **0/9** | 0.914× | 6/9 |
| 512 | **0.899×** | **8/9** | 0.680× | 9/9 |

**Observation:** In this summary, 4 workers were slower than 2 in *every* session/ingress comparison at 0–128 iterations. At 512 iterations, 4 workers were faster in 8/9 comparisons; 2 workers were faster than 1 in all 9. The size-dependent reversal is present even with pool workers reused across three waves, making the fixed worker-start/teardown explanation **insufficient on its own**. A scheduling/synchronization/granularity mechanism is *plausible*, **not directly measured or proven**.

### Concrete medians at ingress capacity 64

Each duration below is the **median across the three session-specific, seven-sample medians** in milliseconds. Ratios in the previous table also include the other ingress configurations, so the columns do not reproduce all headline ratios.

| Iterations/task | 1 worker | 2 workers | 4 workers |
|---:|---:|---:|---:|
| 0 | 1.962 ms | 2.081 ms | 3.039 ms |
| 8 | 2.059 ms | 1.930 ms | 3.341 ms |
| 32 | 2.358 ms | 2.445 ms | 3.720 ms |
| 128 | 4.033 ms | 3.416 ms | 3.816 ms |
| 512 | 7.140 ms | 4.730 ms | **4.272 ms** |

For 512 iterations, the median whole-wave duration at ingress 64 is roughly **1.67× better in throughput for 4 workers than for 1** (7.140 / 4.272), and about **1.11× better than 2** (4.730 / 4.272). This is a throughput comparison for equivalent work **within this P13 workload only**; worker startup, preparation, join and verification are excluded from `waves_ns` and must be assessed separately for one-shot consumers.

## Ingress capacity and diagnostic counters

Small ingress buffers are a strong cost signal when tasks are cheap:

- For 0-iteration tasks, **ingress 8 vs ingress 64** median wave-time ratios across sessions were approximately **1.98× at 1 worker**, **1.95× at 2**, **2.35× at 4**.
- For 32-iteration tasks, those ratios were about **1.74× / 1.79× / 1.80×** at 1/2/4 workers. At 512 iterations, the ingress 8/64 difference was small and sometimes reversed.
- Grouping all **9** `0-iteration` rows (3 sessions × 3 worker counts) at each inbox size, the median `parkCount` changed roughly **488 (ingress 8) → 46 (64) → 23 (256)**; the corresponding median producer `retries` were **1012 → 90 → 4**.
- These counts show observed wake/park/backpressure activity is associated with inbox capacity, **but cannot establish whether parking, condition-variable notifications, producer yielding, owner-local deque traffic, unsuccessful steals, contention or task size is responsible**. The existing M0 `parkCount` is a diagnostic count, not a cycle-accurate measure of blocked time. No per-worker steal histogram or lock wait measurement is in this summary.

The most focused next instrumentation is: aggregate inbox `full`/trySubmit retries, takeBatch sizes, owner pop hits, steal attempts and successes, park/wake counts per worker, and per-worker completed counts, **without altering published M0 code**. Instrumentation overhead and correctness should be qualified against an uninstrumented same-semantics reference.

## Stability and limitations

- The **median within-row observed range `(max−min)/median` is ~44.5%** across 135 rows; some are much wider. A ratio of config medians can show a trend but is not a confidence interval or a matched-run paired analysis.
- The uploaded file holds just each config's median/min/max, not the 7 measured observations and their order. Therefore we cannot reconstruct **within-sweep 4w/2w pairing, order effects, median absolute deviation, per-run outliers, pooled distributions or time-correlated drift**.
- Session labels `session1`–`session3` are present but **their statistical independence is not proven**. We also cannot independently verify compiler/toolchain, native host/affinity, thermal behaviour, frequency governor or whether results span CPU migrations, because the manifest/raw evidence was not included.
- From the summary, there is **no demonstrated 4-worker correctness defect**; all checksum columns agree for the same compute size, but the raw kernel-output assertions cannot be independently audited.

## Engineering disposition and next bounded research

**KEEP:** P13's *qualitative* reversal of worker scaling at large task sizes and substantial sensitivity to ingress capacity when tasks are tiny. It justifies targeted instrumentation and physical-core, frequency-aware repetition.

**DEFER:** choosing a default worker count; optimizing inbox/parking/deque batching; shrinking a general `TaskScope` safety boundary; using GC/stack record costs to explain P13; or claiming C++ parity. The observable trade-off includes size, queue capacity, worker start amortization and outstanding lifetimes, none of which can be collapsed into a single static worker-count rule.

**NEXT (P14 candidate):** run a low-perturbation read-only instrumented research copy of M0 submission/steal/park paths on the **same 1/2/4-worker, 0/32/128/512-kernel workload**, record per-worker event counts and wave durations, and compare against an uninstrumented control. Prefer the full uploaded native P13 archive (manifest + per-sweep CSV) before treating session ratios as paired statistical evidence. Do not touch source/concurrency, `develop`, the grandfathered R0.5 line, ADR PROPOSED, Issue #17 OPEN or Draft PR #38 DRAFT without a separate justified contract decision.
