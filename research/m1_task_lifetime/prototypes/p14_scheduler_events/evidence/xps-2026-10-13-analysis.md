# P14 — Native Dell XPS control-versus-scheduler-events review (2026-10-13)

**Disposition:** **PASS** archive integrity, real-M0 control/trace task equivalence and instrument event accounting; **KEEP** observed short-task failed-steal / parking / ingress-batch activity as explanatory *candidates*; **DEFER** specific bottleneck attribution, performance tuning, general `@safe` lifetime promotion and C++ parity.

## Provenance and privacy

- User-provided original artifact: `p14-xps-2026-10-13.tar.gz`, **246,571 bytes**, **SHA-256 `586d567c62c5f9eb0d99b755fa17fe2597b4265316b785f24ec1c5f089fa0f39`**.
- **The original archive remains in the research exchange; it has NOT been uploaded to this public GitHub repository**, because raw DUB logs and the manifest contain local host, path and user information.
- Manifest source commit **`f4da54539e161c775cb99aa50eb9ed926de0a27e`**, the exact previously compiler-qualified [P14 event overlay and control](../README.md). DUB executes real M0 `SubmissionWorkerPool` / containers-d 0.2.0 in control and an exact-source instrumented research copy in trace.
- LDC **1.41.0**, release build; Intel **Core i7-9750H, 6 physical cores / 12 logical CPUs**. Linux affinity mask **0,1,2,3** maps in the saved `lscpu -e` topology to **four distinct physical cores** (socket 0; core IDs 0–3). **Process-level affinity does not pin individual workers**; threads can migrate within that set.
- Optional sensors snapshots at session boundaries: package-temperature observations approximately **76–81°C**, fan approximately **4,478–5,060 RPM**. These show a warm, actively cooled machine; **there is no continuous CPU clock/temperature or hardware PMU trace** and no proof or disproof of throttling.
- Control and trace process execution order alternates by session: **session 1 control→trace; session 2 trace→control; session 3 control→trace**. The two executions have the same seeded scenario order **within each session**, but are separate processes at different times.

## Raw dataset verification

Original archive contains **six per-mode/session CSV files**, plus six raw logs and diagnostic artifacts:

- Three sessions; **45 configurations = 1/2/4 workers × 0/8/32/128/512 kernel iterations × ingress 8/64/256**.
- Each session/mode contains **2 warm-up plus 7 measured fully shuffled sweeps** (405 rows). Across both modes: **2,430 total recorded rows**, including **540 warm-ups and 1,890 measured rows** (**945 measured control and 945 measured trace**).
- Each run executes **3 waves × 2,048 tasks = 6,144 admitted tasks** on a single actual pool with persistent workers through those waves.
- All six CSVs have complete one-of-each-configuration sweeps, valid order positions, equivalent control/trace row shapes and identical input `count/waves/workers/iterations/ingress/seed` and checksums in **every corresponding row**. All stage times are nonnegative and sum to reported `total_ns`.
- Every trace row satisfies **accepted = submit signals = completed = batch-tasks-claimed = executed = 6,144**, `full = retries`, `park waits = original parkCount`, `local pushes = owner-local pop hits + successful steals`, `executed = batch heads + owner deque pops + steals + failed-push inline executions`, and **sum(per-worker completed) = 6,144**; all inactive worker slots remain zero.
- The uninstrumented control emits **zero research trace events**. These checks agree with the positive runtime validations in the original P14 source. They do **not** prove correctness on injected native OS failures or arbitrary consumer callbacks; the existing M0 `@system`/fail-stop research contract remains unchanged.

## Reconfirmed 4-versus-2-worker scaling on UNINSTRUMENTED M0

Within **each of the 21 measured shuffled sweeps** (3 sessions × 7 measured sweeps), compare the control run's `waves_ns` from four workers against two workers at a fixed kernel and ingress. Aggregate over three ingresses for **63 comparable within-sweep ratios per kernel**. `waves_ns` includes admission, backpressure, scheduler work and wave completion; it **excludes record preparation, native worker creation, final join and verification**.

| Kernel iterations/task | Median 4w / 2w `waves_ns` | Comparisons with 4w faster / 63 |
|---:|---:|---:|
| 0 | **1.788×** | **0** |
| 8 | **1.643×** | **1** |
| 32 | **1.483×** | **0** |
| 128 | **1.195×** | **9** |
| 512 | **0.931×** | **46** |

All three independent sessions show a similar short-task regression direction, while the heavyweight task reverses the ordering **in most, not all, comparisons**. This is stronger evidence than the previous P13 *summary-only* ratios because the original randomized per-sweep observations are available here. It does not by itself identify the responsible synchronization primitive or prove a portable default worker-count policy.

Control median 4w/2w ratios by **ingress** provide useful sensitivity context:

| Iterations | Ingress 8 | Ingress 64 | Ingress 256 |
|---:|---:|---:|---:|
| 0 | 1.642 | 1.793 | 1.882 |
| 8 | 1.556 | 1.676 | 1.854 |
| 32 | 1.539 | 1.502 | 1.422 |
| 128 | 1.388 | 1.088 | 1.075 |
| 512 | 1.009 | 0.884 | 0.910 |

These are **ratios of the two worker counts under a given ingress**, not the absolute effect of changing ingress; even if ingress 8 makes *both* worker counts much slower, their ratio may appear closer to 1.

## What the TRACE COUNTERS actually establish

The next table reports the **median of 21 trace measurements** per configuration (three sessions × seven sweeps), for **6,144 jobs, zero kernel iterations and four workers**. Different column medians do not necessarily describe the same individual run.

| Event / diagnostic | Ingress 8 | Ingress 64 | Ingress 256 |
|---|---:|---:|---:|
| Cross-worker `steal()` attempts | **4,785** | **1,189** | **1,012** |
| Successful steals | **850** | **288** | **236** |
| Unsuccessful steals, difference of individual medians* | approx. 3,935 | approx. 901 | approx. 776 |
| Actual `Condition.wait` entries (`park_waits`) | **642** | **145** | **123** |
| Full-ingress submission retries | **877** | **34** | **1** |
| Tasks per nonempty ingress batch | **4.2** | **6.4** | **6.5** |
| Nonempty ingress batches | **1,472** | **967** | **944** |
| Successful owner-local deque pops | **3,825** | **4,883** | **4,959** |
| Least tasks executed by any worker | **1,423** | **1,348** | **1,328** |
| Most tasks executed by any worker | **1,630** | **1,720** | **1,737** |

\*Difference of medians is presented only as a rough scale. Separate paired medians for failed steal attempts are not identical to subtraction of the attempt and success medians.

**High-priority observational signal:** with very cheap jobs and four workers, reducing ingress from 64 to 8 correlates with substantially more failed-steal search, parking, inbox batch-head executions, admission retries and smaller batches. Ingress does not merely change available queue capacity; it changes timing/interleavings of producer submission, inbox draining and thief searching. **P14 counts correlations, not causal time spent in any path**.

### Worker utilization: not simply three idle workers

All **945 measured trace samples** report **nonzero task executions on every configured worker**. For four workers / zero iterations / ingress 8, across the 21 samples, the median least-loaded worker executed **1,423** tasks and the median most-loaded worker **1,630** (ideal equal share is 1,536 each). Thus **gross task-count starvation is not the explanation** for the four-worker slowdown in this scenario. Task counts are not CPU-time utilization; workers can spend unequal time waiting, stealing, parked or preempted even if final counts are similar.

For four workers / 512 iterations / ingress 256, the medians are more uneven (**minimum worker 1,117, maximum 2,030**) while the four-worker control is usually faster than two workers. **Perfect task-count balance is not necessary for the observed throughput gain.**

### Single-worker control rules out an exclusive steal explanation

With **one worker**, `steal_attempts` and `steal_successes` are always **zero** by construction. Yet at zero kernel iterations, ingress 8 shows median approximately **404 actual park-waits and 1,239 producer retries** across 21 samples, compared with only **10 waits/233 retries** at ingress 64. This is positive evidence that *inbox/backpressure/wake interactions themselves*, not only cross-worker stealing, warrant isolation.

### 4-worker trace details at different kernel sizes

The overhead pattern changes substantially when tasks become heavier:

| Four workers | Ingress 8, iterations 0 | Ingress 64, iterations 0 | Ingress 64, iterations 512 |
|---|---:|---:|---:|
| Steal attempts | 4,785 | 1,189 | **78** |
| Successful steals | 850 | 288 | **18** |
| Park waits | 642 | 145 | **12** |
| Ingress batch size | 4.2 | 6.4 | **8.0** |
| Producer retries | 877 | 34 | **1,346** |

Note that **producer retries increase** under heavy computations because worker consumption takes longer, even as steals and parks diminish. Therefore **retry counts alone are not a measure of scheduler inefficiency**; their interpretation is workload-dependent. Similarly, the event tally does not show time spent blocked on a mutex or condition variable.

## Instrumentation overhead: NO stable multiplicative correction

The trace uses additional instructions and cache-aligned per-worker storage, and more counters in existing inbox critical sections. Per-session median `trace/control` `waves_ns` ratios across all configurations were:

| Session | Process order | Median trace / control |
|---:|---|---:|
| 1 | control→trace | **0.973** |
| 2 | trace→control | **1.030** |
| 3 | control→trace | **0.914** |

The trace **sometimes measures faster** than the control, although it necessarily executes additional bookkeeping. This is evidence of **non-negligible run-order, CPU frequency/cache/scheduling variability**, not evidence that instrumentation optimizes the scheduler. Across work/worker groupings, individual ratios are widely spread; even the three session medians change direction with process order.

**Do not subtract a fixed trace overhead from the counters, multiply timings by an inferred correction, or use traced timings to rank production alternatives.** Use **control** to describe P14 scaling and **trace** to describe path-event distributions. To time a future proposed optimization, compare *two uninstrumented variants* with equivalent semantics, retaining traced versions only for explanatory counts.

## Interpretation and next experiments

**Supported now:** P13's task-size crossover persists on four *distinct physical cores* with reusable workers and is much more reproducible than shared-CI results. When tasks are tiny, M0 performs extra work in **batch claiming / owner-deque operations / unsuccessful steals / parking and producer retries** at high worker counts and especially ingress 8. At a zero-iteration kernel and four workers, every worker actually executes work, so a simple “some workers never run” explanation is contradicted.

**Not established:** exact mutex hold/wait times; relative CPU cycles consumed by steals, notifications, atomics or context switches; a specific bug in containers-d's deque; the true cost of a wake-up; universal optimal batch/ingress size; worker blocking/SMT assumptions; cache/NUMA effects; or a guaranteed C++/Rust-comparable throughput. Only session-boundary thermal data exist.

**P15 candidate:** investigate *one mechanism at a time*, retaining the original M0 source and one additional **research-only, safety-equivalent** variant. Priority is to isolate the per-task global inbox `completeOne` mutex and notification path or, independently, the producer full/backpressure and worker park/wake interplay. Instrument lock wait-time **with calibrated overhead**, then test an optimization only if matched-control native evidence justifies the contract. Do **not** “optimize” by removing completion obligations or weakening join/ownership safety. Keep a control and optimization binary **without instrumentation**, plus separate counter-enabled interpretive runs; use randomized order and preserve exact task results and worker-join lifetime obligations.

**Final decision:** **KEEP P14 evidence**; **NO-GO** for automatic production changes, arbitrary `@safe TaskScope`, native failing-start/join recovery or performance parity to C++ from this experiment. Maintain ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38 DRAFT, no writes to `source/`, `develop` or grandfathered R0.5.
