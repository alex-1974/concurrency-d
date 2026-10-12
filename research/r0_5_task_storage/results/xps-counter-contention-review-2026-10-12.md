# R0.5 Dell XPS — Same-binary shared versus striped counter A/B (2026-10-12)

**Conclusion: The benchmark's single shared atomic execution counter is NOT the dominant explanation of negative producer scaling in the tested R0.5 mixed minimal/compute workloads.** Both existing runtime counter layouts strongly lose throughput as producer concurrency rises from 1 to 4 or 8, while the within-round `striped/shared` performance ratios are typically close to one. **KEEP `freshGc` and `NotificationPolicy.always`; DEFER any admission/inbox/recycler structural change.** This narrows one benchmark confounder; it does **not** prove the outer admission mutex, `Condition.notify`, worker parking, GC or another atomic is causally responsible.

## Immutable evidence, source identity and corrected experiment cardinality

- User-uploaded original `r05-xps-counter-contention.tar.gz`; **SHA-256 `954b927cd065ccd6dbf4f9036208c828f348ce46fa216eda09c1a7c7bcc5f7c8`**. Original archive contains one directory and exactly six regular evidence files: `raw.csv`, `pairs.csv`, `summary.csv`, `producer_scaling.csv`, `producer_scaling_summary.csv`, `environment.txt`. Read and recomputed directly, not edited or committed to Git.
- Recorded exact measurement HEAD **`49e05ac463d543fbb5483b00225346089d93859b`** on the **grandfathered** `perf/r05-owned-task-pipeline` branch. The environment reports no tracked working-tree modifications, which does not exclude untracked files. The binary **SHA-256 `a641dbe3d127bfee57df7a7e44b12db7963682ca93b2633f90450ec5656b0558`** matches the previously reported native uninstrumented CPU/scheduling baseline's binary hash; current source HEAD has additional research-only Python and documentation commits but does not alter the compiled benchmark/scheduler.
- One uninstrumented **LDC 1.41.0 / LLVM 19.1.7 / DUB 1.40.0 optimized release binary** with `R05FullVictimSweep` enabled; explicit `instrumentation=off; parking=off; notify=always` for all children. Same 4 workers, 64-slot ingress, budget512, task families, and compiler. This is R0.5 OwnedTask research, **not** proof about a separate production M0 implementation beyond the corrected full-victim traversal.
- Dell XPS Intel **i7-9750H** (6 physical/12 logical), Linux **6.17.0-22-generic x86-64**, glibc 2.43, CPU governor **`powersave`**. A single `lscpu` frequency-scaling snapshot is **65%**, not sustained operating frequency. No core affinity, controlled AC power, thermal or competing-host-load trace. `perf_event_paranoid=4`; **this driver does not attempt `perf`**, nor modify privileges.
- **IMPORTANT cardinality correction:** An earlier [protocol](../r05-counter-contention-ab-protocol.md) mistakenly predicted **120** processes / **3.6M** tasks and **60** counter pairs, omitting that `shared` AND `striped` each require a fresh process per scenario. The actual experiment (and correct source driver) executed **10 rounds × 2 workloads (minimal/compute-1024) × 3 producer counts (1/4/8) × 1 budget (512) × 2 policies (freshGC/recycleTyped) × 2 counter modes (shared/striped) = 240 independent child processes × 30,000 completed tasks = 7.2 million Tasks**. Thus **120 paired striped/shared samples**, **12 scenario summaries**, **160 per-round 4/1 or 8/1 producer scaling samples**, **16 scaling summary groups**. The protocol's expected counts were corrected separately without altering or rewriting source evidence or measured source revision.

## Strict cross-file data audit

An independent recomputation from original `raw.csv` confirmed:

- **240** unique (round, workload, producers, budget, policy, counter) keys; full factorial coverage, 30,000 actual completed Tasks/case, `fresh_nodes+reused_nodes=tasks` for all 240, **1,765** observed typed handles per case, exactly one binary SHA, `profile_mode=plain` in all cases, positive throughput and external wall `>=` internal timing.
- Both modes and policies preserve the benchmark's `compute` deterministic checksum **`21334545774983`**; minimal workload checksum is 0 by design. Runtime checks in `multi_producer.d` additionally validate exactly-once execution, typed result observation, GC-visible task execution and complete draining. This test does **not** establish a new universal move-only-destructor, `@safe` cross-thread-capture or public ABI contract.
- **120** exact same-round same-workload same-policy `striped/shared` throughput ratios; every ratio and all underlying CPU/switch/GC resource values recalculated and matched `pairs.csv`.
- **12** group summaries: recomputed ten-round medians, minima, maxima, independent median rates and `striped_wins`. **160** exact within-round producer-scaling comparisons, each independently checked against one- and four/eight-producer raw rates using the *same* storage mode and counter mode. **16** ten-round producer-scaling summaries all match their raw input.
- No recorded major page faults. Process `wait4` peak RSS reports the identical value **24,460 KiB in all 240 cases**, thus supplies **no discriminatory memory evidence**. Whole-process CPU/switch totals include producer+worker+other process threads; the D `resource` metrics are producer-only. Their difference is a residual, **not** a verified worker-only sample.

## 1. The counter treatment is nearly neutral overall

Each reported ratio below is the **median of ten paired `striped/shared` throughput ratios**, not a ratio of independently computed median rates. `>1` favors striped; `<1` favors shared.

| Workload | Producers | Storage | Paired median striped/shared | Striped wins /10 | Pair min–max |
|---|---:|---|---:|---:|---:|
| minimal | 1 | GC | **0.8615×** | 3 | 0.686–1.229× |
| minimal | 1 | recycle | **1.0841×** | 8 | 0.656–1.379× |
| minimal | 4 | GC | **1.0154×** | 7 | 0.945–1.093× |
| minimal | 4 | recycle | **0.9992×** | 5 | 0.949–1.146× |
| minimal | 8 | GC | **1.0123×** | 6 | 0.897–1.142× |
| minimal | 8 | recycle | **0.9920×** | 3 | 0.977–1.044× |
| compute-1024 | 1 | GC | **1.0143×** | 5 | 0.628–1.219× |
| compute-1024 | 1 | recycle | **1.0011×** | 5 | 0.650–1.290× |
| compute-1024 | 4 | GC | **0.9589×** | 2 | 0.920–1.128× |
| compute-1024 | 4 | recycle | **0.9687×** | 1 | 0.846–1.028× |
| compute-1024 | 8 | GC | **1.0122×** | 7 | 0.855–1.103× |
| compute-1024 | 8 | recycle | **1.0131×** | 7 | 0.979–1.041× |

- All 120 paired ratios, pooled **descriptive median 0.99934×**, `striped` faster in **59/120** comparisons; **NOT** a population-level no-difference equivalence test.
- 4/8-producer subgroup only, 80 paired ratios: median **0.99764×**, striped wins **38/80**. Effects usually a few percentage points, are sometimes negative, and do not consistently reduce system CPU or switching.
- Pooling the two storage policies only for diagnostic descriptive summaries: minimal 4/8-producer medians **1.0088× / 0.9963×**, compute 4/8 **0.9668× / 1.0129×**; compute four-producer slowdown of striped (~3.3% pooled median) is not a general performance proof and reverses at eight producers.
- Single-producer effects are noisy and can invert across GC versus recycle. A one-producer `striped` counter also has a **different memory address**, so do not force it to 1× by definition or claim an exact zero-cost baseline. The x86 cache line spacing applies to *originating-producer* stripes, **not executing-worker-local** counters. Tasks of one producer can be executed by many worker threads and still contend on the same stripe. Shared `admitted`/`observed`/`computeChecksum` atomics persist.

## 2. Negative producer scaling persists in every matched comparison

The following table uses the **median of within-round 4-producer/1-producer and 8-producer/1-producer throughput ratios**, pooled descriptively over both GC and recycling policies (**20 ratios in each cell**).

| Workload | Counter | 4 producers / 1 | 8 producers / 1 |
|---|---|---:|---:|
| minimal | shared | **0.6532×** | **0.6143×** |
| minimal | striped | **0.6845×** | **0.6626×** |
| compute-1024 | shared | **0.6534×** | **0.6072×** |
| compute-1024 | striped | **0.6515×** | **0.6136×** |

**Crucial integrity fact:** **All 160** within-round producer scaling ratios are **<1.0**, with the highest only **0.8397×**. Not one matched four/eight-producer case outperforms its respective single-producer control under either counter layout. (These ratios are correlated because multiple factor groups share single-producer denominators; **do not** treat them as 160 independent randomized replicates or a precise p-value.)

The ten-round individual storage/policy scaling summaries agree. For example compute-1024 GC: shared 4/1 **0.6482×**, 8/1 **0.6072×**; striped 4/1 **0.6279×**, 8/1 **0.6311×**. Both variants remain well below parity. The native experiment thus **rejects the practical hypothesis that merely switching the benchmark's existing shared execution counter to producer stripes will restore scaling** in the tested scenario.

## 3. More CPU and context switches at 4/8 producers under *both* counter layouts

Medians across 20 separate (GC/recycle × 10 rounds) child processes per (workload, producer count, counter) group; full process metrics, not a causal lock/worker assignment:

| Workload | Producers | Counter | Throughput tasks/s | CPU seconds / 30k tasks | Voluntary switches / 30k tasks |
|---|---:|---|---:|---:|---:|
| minimal | 1 | shared | 213,335 | 0.464 | 37,729 |
| minimal | 1 | striped | 202,229 | 0.472 | 37,777 |
| minimal | 4 | shared | 139,642 | 0.777 | 76,956 |
| minimal | 4 | striped | 139,905 | 0.780 | 75,736 |
| minimal | 8 | shared | 135,168 | 0.804 | 76,214 |
| minimal | 8 | striped | 135,547 | 0.799 | 76,076 |
| compute-1024 | 1 | shared | 258,128 | 0.424 | 20,116 |
| compute-1024 | 1 | striped | 266,850 | 0.422 | 21,289 |
| compute-1024 | 4 | shared | 172,742 | 0.731 | 58,112 |
| compute-1024 | 4 | striped | 164,837 | 0.759 | 58,549 |
| compute-1024 | 8 | shared | 159,689 | 0.788 | 59,640 |
| compute-1024 | 8 | striped | 162,924 | 0.772 | 59,700 |

Among only the 80 4/8-producer counter pairs, descriptive medians of paired `striped/shared` metrics: **1.00149× child CPU seconds** and **1.00298× whole-child voluntary switches**; virtually unchanged. For compute-1024 4p specifically, the paired median CPU ratio is ~**1.033×** and switches ~**1.026×** when switching to stripes; at compute 8p the ratios are ~**0.987×** and **0.999×**. Nothing suggests stripes generally mitigate a large amount of process scheduling cost.

Whole-child voluntary switch counts are already large for one producer and climb strongly at four/eight with both layouts. Producer-only voluntary switches also climb; the remainder includes worker and other threads but cannot be assigned to an exact worker or a particular `futex`, GC pause or condition variable without more evidence. `perf` was not run under this driver, and `wait4` context switches are not causality evidence.

## 4. Reconciliation with earlier campaign and defensible next work

- Earlier uninstrumented [native system CPU study](xps-native-system-cpu-scheduling-review-2026-10-12.md) used the **same binary SHA** and shared execution counter but only five rounds and different order/host conditions. Its one-producer absolute rates (especially compute-1024) differ materially from this campaign. The `powersave` snapshot is not controlled CPU frequency; thermal state, scheduling drift and background activity remain possible. **Never pool campaigns as iid same-conditions trials or infer a cross-campaign regression from absolute throughput alone.**
- The earlier [native inbox-notify study](xps-inbox-submit-review-2026-10-12.md) measured `Condition.notify()` at ~1µs producer-side *with intrusive stage/inbox probes*. The separate [waiter-aware A/B](xps-notification-ab-review-2026-10-11.md) was not consistently beneficial. These are **different designs and workload settings**: neither proves that skip-notify or lock-free publication is the answer now.
- This A/B alters **only benchmark counter locality**. A negative result reduces that confounder in *this exact mixed 4-worker workload*; it does not eliminate all application-dependent synchronization (void checksum, result observation/admission counters, GC) or prove admission mutex implementation is sole culprit.

**Engineering decision:** KEEP `freshGc` default and `NotificationPolicy.always`, preserve full victim traversal and existing GC-root-before-publication/retention/backpressure/close guarantees. **DEFER** indexed recycler, inbox mutex replacement, changing wake generation/notifications, worker affinity and moving allocation outside lock absent comparative evidence.

**Next highest-value research discriminator:** instrument **only the boundaries around producer/worker execution lifetimes**, not the Task hot path: capture worker-local CPU and voluntary/involuntary context switches at thread shutdown (and/or safely sample Linux per-thread scheduler counters while a bounded workload runs), without changing actual queue/TaskRef behavior. Correlate per-thread evidence with 1/4/8 producer scaling under minimal and compute-1024 with both counter modes. This is needed to distinguish worker scheduling/parking/notification from outer admission serialization. A second, independently paired constrained admission specialization is appropriate only after a concrete mechanism is isolated and lifetime/close semantics are verified. No architectural promotion from this report.

Grandfathered Draft PR #35 and Issue #20 stay open. The research report documents a negative hypothesis and **does not** merge this long-lived research branch to `develop`, change public API/CI release gates, or edit other workspace repositories.
