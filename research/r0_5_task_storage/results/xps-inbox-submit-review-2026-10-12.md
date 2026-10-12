# R0.5 XPS — Native inbox mutex, enqueue and notify profile (2026-10-12)

**Decision: KEEP `freshGc`, the existing `NotificationPolicy.always`, the bounded inbox and generation-safe condition-variable protocol. DEFER restructuring the inner or outer mutex and any general typed recycler promotion.** The native data localize a *large instrumented inbox hold component* to the producer-side `Condition.notify()` call, but do **not** demonstrate that suppressing or replacing it safely improves throughput. A previous independent native [waiter-aware A/B](xps-notification-ab-review-2026-10-11.md) was essentially neutral and was not promoted; the present cost breakdown must be interpreted alongside that negative evidence.

## Original archive, source and integrity

- User-provided archive: `r05-xps-inbox-submit.tar.gz`, **SHA-256 `ea8d3939233bcae6ac56e276bc09207fafcd63df55e047c7c33bf59f13cc11e1`**. Exactly five evidence files in its single `r05-xps-inbox-submit/` directory: `raw.csv`, `pairs.csv`, `diagnostics.csv`, `summary.csv`, `environment.txt`. The original archive is retained outside repository Git history and was inspected without executing its contents.
- `environment.txt` pins measured **HEAD `24d613a8d261bbb636052f0e3df728fbb0b77f68`**, `compiler=ldc2`, **LDC 1.41.0** (DMD frontend 2.111.0, LLVM 19.1.7), DUB 1.40.0, Linux 6.17.0-22-generic / glibc 2.43 x86-64 on Intel Core **i7-9750H** (six cores/twelve threads). CPU0 governor `powersave`; `lscpu` scaling snapshot 93%, **not** a sustained in-run frequency. No recorded CPU pinning, thermal trace, background task load or measured wake-to-run latency.
- Source HEAD verified against the grandfathered R0.5 research branch: `R05FullVictimSweep` uses complete N-position, skip-self search as in the narrow M0 correction accepted through PR #37 (`develop` squash `7af4409a2e09a303dfbc6c54033d28c92eb67581`). **The R0.5 OwnedTask executor is otherwise a different experiment from production M0**. The benchmark uses separate uninstrumented `off` and opt-in `R05AdmissionStageProbe` + `R05InboxSubmitProbe` `on` release binaries, both `NotificationPolicy.always`.
- Exactly **5 rounds × 1/4/8 producers × budgets 8/512 × fresh GC/typed recycle × on/off = 120 fresh Linux child processes**, each with four workers and 30,000 completed *minimal*, shared-counter, mixed typed/GC-visible/void Tasks: **3,600,000 completed in total**. The 60 profiled child processes contribute **1,800,000 accepted inbox submissions and exactly 1,800,000 actual `notify()` calls**. Cross-mode throughput changes include profiler perturbation.

### Independent cross-file verification

The original CSVs were parsed again, and all values cross-checked from `raw.csv` rather than trusted as summary claims:

- `raw.csv`: **120 unique five-factor keys** and all complete combinations; every child has `completed=30,000`, `fresh_nodes+reused_nodes=30,000`, `observed_handles=1,765`, valid positive throughput and expected off/on field presence.
- `pairs.csv`: **60 exact within-round GC/recycle pairs**; every computed ratio matches the two corresponding raw throughput rates.
- `diagnostics.csv`: **60** on-mode policy cases; inner wait/hold, enqueue/notify means, inner-vs-outer diagnostics and stage means reproduce from the cumulative raw nanoseconds/counts.
- `summary.csv`: **12** scenario/mode summaries, five pairs each, with independently reproduced medians and recycling-win counts.
- All **60** profiled cases satisfy outer `gate_count=attempts=30,000+retention_full+ingress_full`, `cell_count=node_count=publish_count=root_append_count=inbox_submit_count=accepted=30,000`; inner `attempts=accepted=enqueueCount=notifyCalls=30,000`, `notifySkipped=rejectedFull=rejectedClosed=0`. Profiled `ingress_full=0` throughout; total **616 retention-full attempts** across 20 of 60 profiled processes. The independent benchmark's accepted, executed, result, GC-visible-capture, completed/drain checks all passed.
- Every run has `inbox_enqueue_ns + inbox_notify_ns <= inbox_hold_ns`, and `inbox_wait_ns + inbox_hold_ns <= inbox_submit_ns`. **Do not** infer these are exact additive uninstrumented cycle decompositions. `git status --short --untracked-files=no` reports no tracked changes, but does not certify that no unrelated untracked research files existed.

## A. The queue enqueue is cheap; the instrumented notify call dominates inner hold

Values below are **medians of independent per-process means**, across all 60 on-mode runs. All nanoseconds are elapsed wall-clock time *at the respective probe*; inner wait also includes scheduling and the effect of other worker operations.

| Instrumented interval | Median per accepted task | Across-run min–max |
|---|---:|---:|
| Time waiting to acquire inner `TaskInbox._mutex` | **579 ns** | 425–698 ns |
| Inner mutex hold, including instrumentation | **1,273 ns** | 833–1,463 ns |
| Queue slot/counters/generation (part of hold) | **53 ns** | 32–59 ns |
| `_changed.notify()` **call duration** (part of hold) | **1,053 ns** | 660–1,220 ns |
| Enclosing `_pool.trySubmit()` from outer producer | **3,021 ns** | 2,191–3,533 ns |

Within-run ratio medians: `notify_ns/inbox_hold_ns` **82.82%** (range 79.22–83.89%), `enqueue_ns/inbox_hold_ns` **4.11%** (3.70–4.78%), inner mutex `wait_ns/inbox_submit_ns` **19.92%**, inner hold `hold_ns/inbox_submit_ns` **41.65%**, and `notify_ns/inbox_submit_ns` **34.61%**. The **median residual** of the outer composite `inbox_submit_ns - inbox_wait_ns - inbox_hold_ns` is **1,139 ns per accepted task**, about **38.68%** of the instrumented composite; it encompasses outer/inner timer overhead, call boundary work, scheduler/compiler effects and unbracketed instructions. This sizable gap means even the inner split **does not** offer a complete causal breakdown of `_pool.trySubmit()` or a verified absolute upper bound for an optimized release binary.

The sum of producer-side per-task event durations is not total elapsed application wall time; producer threads can run concurrently (until serialized by the outer admission mutex) and have scheduling delays. `Condition.notify()` latency here is the time spent in the *producer's call*, **not** worker notification-to-wakeup/run latency, usefulness of a wake, or a substitute for a wake-tail SLA.

### Factor-level medians (five on-mode runs per policy/producer/budget)

Times in **nanoseconds/event**, from each raw case's cumulative counters divided by events, followed by the median of five cases. This is one study with shared compiler and task semantics, not an iid population.

| Producers | Budget | Policy | Inner wait | Inner hold | Enqueue | `notify()` | Outer composite inbox submit |
|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | 8 | GC | 504 | 886 | 36 | 720 | 2,316 |
| 1 | 8 | recycle | 499 | 999 | 38 | 824 | 2,451 |
| 1 | 512 | GC | 497 | 966 | 38 | 793 | 2,389 |
| 1 | 512 | recycle | 485 | 989 | 41 | 798 | 2,547 |
| 4 | 8 | GC | 564 | 1,330 | 52 | 1,111 | 3,020 |
| 4 | 8 | recycle | 559 | 1,253 | 50 | 1,045 | 2,868 |
| 4 | 512 | GC | 569 | 1,275 | 53 | 1,052 | 2,999 |
| 4 | 512 | recycle | 592 | 1,333 | 54 | 1,093 | 3,077 |
| 8 | 8 | GC | 638 | 1,339 | 55 | 1,114 | 3,198 |
| 8 | 8 | recycle | 625 | 1,295 | 54 | 1,082 | 3,036 |
| 8 | 512 | GC | 640 | 1,308 | 55 | 1,084 | 3,090 |
| 8 | 512 | recycle | 643 | 1,296 | 55 | 1,070 | 3,176 |

**Interpretation within this probe only:** slot and metadata updates are not the bulk of inner hold cost in any tested group; actual `Condition.notify()` call duration is most of inner hold. The time before acquiring the inner mutex is significant but smaller and much less sensitive to producer count than the *outer* admission mutex acquisition wait.

## B. Outer producer contention remains much larger at four/eight producers

Each producer-count row aggregates **20 heterogeneous on-mode storage/budget/round cases**, and hence is a descriptive grouping, **not** an exact paired causal intervention.

| Producers | Outer admission wait ns/attempt | Inner inbox wait ns/accepted | Inner hold ns/accepted | `notify()` ns/call |
|---:|---:|---:|---:|---:|
| **1** | **45** | **498** | **977** | **795** |
| **4** | **17,796** | **573** | **1,285** | **1,067** |
| **8** | **43,987** | **639** | **1,300** | **1,081** |

Because `OwnedTaskExecutor._mutex` already serializes producer entry into `_pool.trySubmit()`, the **inner inbox mutex is not contended by two concurrent producers through this owned path**. Its wait is most plausibly tied to worker ingress/park/completion operations, GC pauses and OS scheduling. The pronounced outer wait growth with producer count is compatible with serialization plus preemption, **not** proof of a single isolated lock cause or a prediction that reducing notify call time by 1 µs would reduce outer waits proportionally.

## C. Uninstrumented throughput does not support a general recycle or notification change

These are the **median of five same-round** unprofiled `recycleTyped / freshGc` throughput ratios; ratios are not quotients of separately grouped median throughputs:

| Producers | Budget | Unprofiled recycle/GC | Recycle wins / 5 | Pair range |
|---:|---:|---:|---:|---:|
| 1 | 8 | **1.0152×** | 3 | 0.9415–1.0741× |
| 1 | 512 | **1.0040×** | 3 | 0.8286–1.1291× |
| 4 | 8 | **0.9980×** | 2 | 0.9496–1.0133× |
| 4 | 512 | **1.0004×** | 3 | 0.9372–1.0813× |
| 8 | 8 | **1.0021×** | 3 | 0.9194–1.0142× |
| 8 | 512 | **1.0083×** | 4 | 0.9973–1.0388× |

Across 30 heterogeneous **off-mode** pairs, descriptive median **1.00528×**, recycling faster **18/30**. The corresponding *on-mode* pooled median is **0.98743×**, recycle faster **13/30**, demonstrating that opt-in timing/codegen can change the apparent direction; neither pooled result is a universal speed guarantee. Both policies' independent overall *off* median rates are ~334k/329k tasks/s at one producer, ~189k/189k at four and ~188k/186k at eight, with budget mixing and single-thread jitter. This again suggests producer scaling is a broader admission/workload issue; **small paired storage ratios cannot justify changing default allocation**.

Peak RSS is essentially a constant reported high-water mark in this 30k-task experiment (**119/120 cases: 19,104 KiB; one 18,920 KiB**). This campaign cannot resolve memory-policy RSS trade-offs. Producer-thread `GC.allocatedInCurrentThread()` is not whole-process GC allocation or attribution to specific publishing stages.

## D. Crucial prior evidence: the conservative `waiterAware` policy was already measured

This research branch already contains a separate **native 2026-10-11 waiter-aware notification A/B** ([report](xps-notification-ab-review-2026-10-11.md), original source SHA `588cdcdbd87fb6c379074db179f6ccaeb13f2a7e`, different workloads/counter settings):
- Unprofiled `waiterAware / always` median across 60 heterogeneous same-round comparisons was **0.9937×**, with **28/60 wins**.
- In the **fresh GC minimal** workload it was **1.0142×** at four producers and **0.9848×** at eight producers; **fresh GC compute-1024** was **1.0186×** and **0.9889×** respectively. The small benefit at four producers did **not** generalize to eight.
- Waiter-aware skipped ~11.4% of ingress `notify` calls for fresh GC minimal at four/eight producers (and more for compute), with little change in empty first searches after waits.
- A separate idle/low-arrival five-round latency experiment found noisy tails (one large p99 outlier); its conclusion was **KEEP always / DEFER waiter-aware**. The earlier head has an incomplete victim scan unless explicitly version-enabled and uses `striped` execution counters and budget512, so **do not combine** the throughput magnitudes with this post-PR37 `full` + `shared` study as identical A/B baselines.

Therefore the present demonstration that a measured `notify()` call is expensive **does not overturn** the existing native negative result for a semantically conservative way of skipping some notifications. Under `always`, a notification may be issued with no sleeping worker; the measured `notifyNs` does **not** identify the presence of a waiter, and the baseline `_sleepers` count is not maintained under that policy.

## Decision and next discriminating task

1. **KEEP** the production/default `freshGc`, ordinary `NotificationPolicy.always`, full foreign-victim scan, strong-root-before-publish ordering, bounded capacity rejection before GC task allocations, and both existing locks/lifecycle/epoch predicate.
2. **DEFER** typed recycling, an indexed spare cache, a new queue/lock-free inbox, removing notifications or changing notification targets. The current profile is not proof of net speedup for any of these; avoid compounding research variants.
3. The next defensible performance discriminator is a **native uninstrumented system-level profile and controlled policy comparison on the *same current full-victim code***, explicitly distinguishing no-wait versus actual sleeping-worker cases and measuring syscall/futex activity, worker wake usefulness/tail latency, producer CPU and context switches. Do not silently reuse the earlier pre-PR37 waiter-aware results as if they were same-code version comparisons. If a new notification strategy is proposed, isolate it behind a separate research configuration, preserve lost-wakeup protection, nested/blocking-task forward progress and exact TaskRef lifetime, and require matched throughput *and* latency evidence.
4. If CPU profiling instead shows substantial time in the **outer admission serialization or GC/result-handle allocation**, redirect efforts there. The 1/4/8-producer delay growth is a different concern from inner notify call duration. A 1µs producer notify measurement by itself does not explain a ~44µs outer mutex wait or dictate a lock redesign.
5. The original archive and prior study remain immutable. Keep the grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35) and [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20) open; **no broad research merge to `develop`**, no API/memory model change, and no other workspace repository edits.

This experiment answers the narrow question **"which part of the instrumented inbox submit dominates?"**: producer-side condition notification dominates the *inner hold*, whereas the queue slot/generation writes take only tens of nanoseconds. It does **not** yet answer **"which alternative is faster and equally correct?"**
