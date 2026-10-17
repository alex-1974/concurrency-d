# P16.1 — Complete native Dell-XPS lower-intrusion completion sampling review (2026-10-13)

**Disposition:** **PASS** original raw archive integrity and matched results; **KEEP** the low-intrusion diagnostic design as a substantially less perturbing probe than P15; **DEFER** specific uninstrumented Mutex wait/hold attribution, a production completion rewrite, a default worker-count rule, and public `@safe` promotion.

## Original evidence and provenance

- Uploaded original **`p16-xps-2026-10-13.tar.gz`**, SHA-256 **`c256cb16e0dc15d2bfd69f3bd216d3f57b233d34d0d1522ce2d3de870114d816`**; original archive is **not copied to public GitHub** because its manifest and DUB logs contain local machine/user/path information. The original archive remains with the research exchange; this document reports source-derived aggregates.
- Source `git` commit **`69ae6de917b743f2b4f08ca421a2dcd08558951d`**, original M0 Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, LDC **1.41.0** (DMD frontend 2.111.0, LLVM 19.1.7), DUB **1.40.0**, full DUB **release** build. The control arm imports **unchanged production M0 `SubmissionWorkerPool`**, the other two import a separately named **exact-source research copy**. Root production sources, manifest and scheduling semantics were not modified.
- Target: Dell XPS 15, Intel Core **i7-9750H (6 physical cores / 12 logical CPUs)**, process affinity **0,1,2,3**, confirmed by the saved `lscpu -e` as **four different physical cores**. This is **not per-thread worker pinning**.
- Three complete sessions with cyclic process order: **session 1 control→null-clock→sampled; session 2 sampled→control→null-clock; session 3 null-clock→sampled→control**. Each mode used the same randomized scenario seed/order **within that session**. The three arms are separate processes, not simultaneously matched executions.
- Optional `sensors` snapshots around the sessions show the host was warm (e.g. package temperatures near **81°C/89°C/91°C** at respective session starts); without continuous clock/temperature counters, **thermal/turbo or scheduling effects cannot be ruled out or quantified**.

## Exact original-data checks

- **Nine per-mode/session CSVs** and nine corresponding original DUB logs, plus manifest/diagnostics/summary, inspected from the supplied archive.
- Each session/mode has **45 scenarios × (2 warm-up + 7 measured sweeps) = 405 rows**. Entire archive: **3,645 rows = 810 warm-ups + 945 measured controls + 945 measured null-clock + 945 measured sampled**.
- Each row executes **3 waves × 2,048 tasks = 6,144 actual completed TaskRefs**, same deterministic kernel at 0/8/32/128/512 iterations, ingress 8/64/256 and workers 1/2/4. The real native pool remains alive across all three waves, then joins.
- All **81 full mode-session sweeps** (three sessions × three modes × nine sweeps, including **63 measured** and **18 warm-up sweeps**) contain exactly one of each of the 45 combinations, with **complete nonduplicated order indices**. Control/null-clock/sampled rows match **session, phase, round, order, seed, workers, count, waves, iterations, ingress and checksum** exactly. Within each kernel intensity the checksum is constant across all 3,645 runs. No missing values.
- Every row satisfies **`prepare_ns + pool_start_ns + waves_ns + join_ns + verify_ns = total_ns`** exactly, with nonnegative stage durations. Control fields `sample_calls/sample_count/sample_sum_ns/sample_max_ns/sample_anomalies` are **all zero**.
- Both P16 research modes report **`sample_calls = 6,144`** per run, nonnegative sample durations, sample max no greater than sample sum, and **zero clock anomalies**. The one-in-64 per-worker sampling produces **96 samples with one worker**, **95–96 with two**, and **93–95 with four**, consistent with expected `sum_i floor(completions_i/64)`; the running D fixture separately asserts the exact per-worker equality after native join.
- Exact per-job input/output oracle, afterExecution lifetime flags, total `accepted == completed` and join obligations are retained from the P13 kernel and actively validated even in release mode. The archive does **not** inject native worker-start/join exceptions or establish a public `@safe` contract.

## Three-arm perturbation: substantially less than P15

Primary comparison is **`waves_ns`**, not whole process time: the same P13 work, after record preparation and pool startup but **before** final join/verification. These are ratios of separate, matched scenario/seed/order process runs: correlated comparisons **but not adjacent randomized AB/BA pairs at the individual configuration level**.

| Metric across all 945 measured matched configurations | Median ratio vs unchanged M0 |
|---|---:|
| **P16.1 null-clock/control** | **1.015×** |
| **P16.1 sampled/control** | **1.035×** |
| P16.1 sampled/null-clock | **1.017×** |
| **P15 timed/control**, from previous native XPS | **2.145×** |

P16.1 sample/control medians **by kernel**: **1.022× / 1.006× / 1.037× / 1.044× / 1.073×** for **0 / 8 / 32 / 128 / 512** integer iterations. Null/control medians: **0.997× / 1.010× / 1.013× / 1.000× / 1.044×** respectively. The measurement perturbation is therefore far smaller by this matched-work criterion, though not strictly zero and not automatically acceptable for every task class.

| Session | Process order | Median null/control | Median sampled/control |
|---:|---|---:|---:|
| 1 | control→null→sampled | 1.024× | 1.033× |
| 2 | sampled→control→null | 1.024× | 1.056× |
| 3 | null→sampled→control | 0.999× | 1.023× |

**Dispersion caution:** per-run ratios overlap substantially and occasionally reverse. Across the 945 configurations, the observed null/control ratio ranged **0.588–2.019×**, and sampled/control ranged **0.526–2.393×**. These extremes are process timing noise, scheduling/interleaving or frequency effects, not an indication of literal probe speedups. Repeated configuration results share sessions and hardware conditions and must not be treated as 945 statistically independent random experiments. Do **not** assign a precise 1.5% or 3.5% causal instrumentation cost or subtract it as a universal correction.

## Lower-intrusion whole-call observations (sampled variant only)

Each worker samples its **own every-64th completed call**; its single-owner, cache-aligned sample struct is read after successful native join. Both probes use **two `MonoTime.currTime` reads**. Null-clock takes them adjacently **before** the call. Sampled takes one before and one **after the entire original `completeOne()` call**. Thus the sampled interval includes the **whole** method call, mutex acquisition, condition/notification work if applicable, critical-section work, unlock and possible descheduling. It **cannot separate mutex wait from hold**.

The following are **medians across 315 measured configurations per worker count of each run's `sample_sum_ns / sample_count`**; they are not individual-call medians and do not constitute an independently sampled tail-latency distribution.

| Worker count | Null-clock adjacent-timestamp interval | Sampled entire completion-call interval |
|---:|---:|---:|
| **1** | **21.0 ns** | **160 ns** |
| **2** | **22.3 ns** | **316 ns** |
| **4** | **22.8 ns** | **606 ns** |

Across the full trace, median per-run null-clock interval is approximately **22.1 ns**, and median per-run whole-call sampled interval approximately **322.9 ns**. The observed whole-call duration increases sharply with worker count **in this low-intrusion research clone**, supporting a **plausible shared synchronization pressure hypothesis**. This does **not** prove the whole production Mutex intrinsically costs those numbers, quantify blocked time, or identify what fraction is allocation, thread scheduling, notification, mutex service, or clock overhead.

### Work-size sensitivity of the sampled call

The medians of per-run sampled means (ns) by kernel intensity and worker count are:

| Iterations / task | 1 worker | 2 workers | 4 workers |
|---:|---:|---:|---:|
| 0 | 171 | 291 | 531 |
| 8 | 167 | 285 | 597 |
| 32 | 180 | 339 | 650 |
| 128 | 215 | 452 | 725 |
| 512 | **91** | **260** | **479** |

**Crucial counterexample to a simple cost model:** the *same* completion method can appear much faster for 512-iteration tasks than 128-iteration tasks at one worker, reflecting changed producer/worker overlap, lock interleavings, cache/power state and sampling selection. It would be wrong to treat **606 ns** or any per-worker median as a fixed per-TaskRef cost to subtract from end-to-end timings.

Original data include maxima up to **659 µs** in rare individual sampled complete-call observations, reflecting potential preemption/outliers; per-run means are not independent individual-call distributions. Optional OS scheduler and `perf stat` evidence could help distinguish CPU/descheduling from normal lock contention, but is **not contained here**.

## Unmodified control: workload-size crossover persists

Using **ONLY unchanged-M0 control runs**, each full measured sweep has the same-work 4-worker/2-worker `waves_ns` comparison per ingress. For each kernel this gives **63 within-sweep ratios** (3 sessions × 7 sweeps × 3 ingresses).

| Compute iterations/task | Median 4w/2w control wave time | Cases where 4 workers win / 63 |
|---:|---:|---:|
| 0 | **1.563×** | **0** |
| 8 | **1.540×** | **0** |
| 32 | **1.344×** | **1** |
| 128 | **1.069×** | **20** |
| 512 | **0.864×** | **56** |

This reproduces the **direction** of P13–P15's same-P13-kernel scaling crossover at roughly 128–512 compute iterations, without making the numbers identical across experiments. The 0-iteration ratio varies somewhat between sessions, showing the remaining clock/machine sensitivity: by session **1.568×, 1.585×, 1.544×** for 0 iterations and **0.818×, 0.867×, 0.882×** for 512. There are only three sessions, so no cross-machine or general scheduler-policy inference is warranted.

### One concrete comparable example: ingress 64

Median unchanged-M0 `waves_ns` across 21 measured runs per (kernel, worker) in milliseconds:

| Iterations | 1 worker | 2 workers | 4 workers |
|---:|---:|---:|---:|
| 0 | 1.436 | 1.208 | 2.034 |
| 8 | 1.484 | 1.254 | 1.977 |
| 32 | 1.740 | 1.492 | 2.061 |
| 128 | 2.923 | 2.328 | 2.407 |
| 512 | 5.415 | 3.198 | **2.687** |

These times represent the **same 6,144 tasks on the same M0 pool with different worker counts**, excluding pool creation and teardown. They do not compare against semantically different `OwnedTaskExecutor`/C++/Rust implementations.

## Calibrated, qualified decision

**PASS / KEEP:**
1. Three modes have identical seed, scenario order, exact result checksum, task counts and native worker join obligations in every archive row. Complete raw evidence is present and SHA-256-pinned.
2. P16.1 reduces the observed sample/control perturbation from P15's **2.145×** to approximately **1.035× median**; a separate null-clock control is typically near baseline. The timing probe is materially more useful for qualitative investigation.
3. Entire `completeOne()` sampled-call durations tend to rise with worker count, **consistent with** shared synchronization pressure. The same task-size crossover persists on unchanged M0.

**DEFER / NO-GO:**
- Converting sample/null differences to **exact intrinsic Mutex wait/hold time**: clock calls, different processes, deterministic sampling, scheduling overlap and worker/producer interactions remain.
- Rewriting production M0 per-task completion/notification, reducing accepted/completed or final wake obligations, altering worker-count policy, claiming generic `@safe TaskScope`, or quoting C++ parity.
- Treating 945 matched row ratios as 945 independent machine sessions or estimating a cross-CPU confidence interval.
- Claiming thermal stability, per-worker physical-core pinning, exact hot-path codegen identity or reliable native startup/join failure handling.

**Bounded P16.2 option now justified:** design and test **one isolated, semantically equivalent completion-accounting variant** using a separately named, exact-source research M0 copy. Preserve atomicity between `completed`, `closed`, generation and notifications; guarantee no lost wake-ups and an independently verified full-join boundary. Compare **two uninstrumented implementations** with all P13 workload results, failure modes and lifecycle obligations matched, randomized native runs and optional read-only OS profiling. Do **not** weaken the data contract merely to eliminate a lock. Begin with an explicit close/completion/park state-machine proof and adversarial race tests **before** accepting timing improvements. ADR-0001 stays **PROPOSED**, Issue #17 **OPEN**, PR #38 **DRAFT**, `source/`, `develop` and grandfathered R0.5 preserved.
