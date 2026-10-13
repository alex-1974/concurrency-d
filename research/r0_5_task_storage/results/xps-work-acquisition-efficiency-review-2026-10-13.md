# R0.5 XPS — Work-acquisition efficiency from existing counters (2026-10-13)

**Decision:** The existing worker-owned count data show **declining steal-hit probability and increasing search/parking event pressure per completed Task as producer concurrency rises from 1 to 4/8**. A new native measurement or new scheduler counter is **not needed** to establish these event-count observations. **No causal nanosecond/CPU attribution or safe faster alternative is established.** KEEP `freshGc`, `NotificationPolicy.always`, complete foreign-victim sweep and current GC-root/ownership/wakeup invariants; DEFER any broad task-queue, worker-spin or admission redesign.

## Evidence, reproducibility and source identity

Reanalysis of the **original previously uploaded** `r05-xps-worker-parking-correlation.tar.gz`; verified SHA-256 **`7399fffb161305adc6adfba293af8720b97a051b2bdb612b857eaa3405d8dbff`**. Original measured source HEAD **`1f97cf5616c67b670d2b601ba4a716822d197bd5`**, XPS i7-9750H, LDC 1.41.0/LLVM19.1.7, full N-slot worker-victim search, `NotificationPolicy.always`, 4 workers, 30k mixed typed/GC-visible/void Tasks per process, budget512, `counter=shared`. These are **R0.5 research** results, not production M0.

The input includes 180 isolated child-process rows across 5 rounds × minimal/compute × producers 1/4/8 × fresh GC/recycle × plain/worker/combined. **Only the 60 `combined` processes** (with original parking/wake/steal counters ON) are used for per-task acquisition metrics. OFF and worker-only rows corroborate source/binary identity and the 60 matched triplets; they are **not** filled with synthetic zeros for absent counters.

Source counters live in `WorkerParkingStats` and `InboxParkingStats` in `source/concurrency/internal/submission_pool.d`. The existing [joint worker + parking profile](xps-worker-parking-resource-correlation-review-2026-10-13.md) verified worker/context-switch accounting and no missing tasks. This review independently re-read all raw CSV records and rechecked:

- **60 complete matched combined-mode cases**, 30k Tasks accepted/claimed/executed/completed each; typed handle and deterministic checksum invariants preserved.
- `stealAttempts >= stealSuccesses`, `failedSteals == stealAttempts - stealSuccesses`, `claimedTasks == executions == ingressNotifications == ingressNotifyCalls == tasks`; no skipped ingress/local notifications under `always`.
- Every worker `conditionWait` returns; all returned wait states and first following search outcomes exactly partition the observed returns. No invented event source or causal wakeup attribution.
- Original raw archive unchanged. [Six normalized by-producer-group medians](xps-work-acquisition-efficiency-2026-10-13-summary.csv) and [12 policy-specific medians](xps-work-acquisition-efficiency-2026-10-13-by-policy.csv) are compact **derived** outputs, not substitutes for the original raw archive.
- Reproducibility: `r05_worker_parking_correlation.py` now also writes `acquisition.csv` and `acquisition_summary.csv` **purely after all child processes and worker joins** from the same pre-existing raw counts. No D implementation, per-Task counter or mutex change. An independent standard-library Python replay of the archived raw.csv produced the derived tables; local unit tests covered the division-by-zero/missing-rate case, broken conservation and missing triplets. The replay script/data are external to the Git source; the Git driver carries the ongoing reproducible computation.

## Per-run normalization and denominators

For each **individual** completed 30k-Task combined-mode process, compute:

- `localMisses / completed`: owner-local pop found no Task. This is a **search-path visit count**, not the number of distinct Task acquisitions or time spent trying.
- `ingressMisses / completed`: `takeBatch()` returned empty after owner-local miss.
- `stealAttempts / completed` and `(stealAttempts-stealSuccesses) / completed`: work-steal probe pressure, including probes of another worker's empty deque.
- `stealSuccesses / stealAttempts`: probability that an observed **steal attempt** obtains a Task in this workload, **not** the fraction of Tasks acquired via inbox/steal or a task-completion success probability.
- `(stealAttempts-stealSuccesses) / stealSuccesses`: number of unsuccessful steal probes per *successful steal*, not CPU cycles and **not** unsuccessful entire work-acquisition rounds.
- `parkChecks / completed`: worker attempts to enter the generation-safe parking protocol, not necessarily entered `Condition.wait()`.
- `conditionWaits / completed`: actual condition wait calls, not OS context switches.
- `completed / claimedBatches`: mean Tasks per successfully claimed inbox batch within that process; max claim buffer is eight Tasks, but a guarantee of eight available Tasks was never made.
- `wokeToEmptySearch / finalWaitExits`: fraction of first search cycles following a completed wait which find no Task; this is **not** the fraction of unnecessary `notify()` calls. Final wait exits exclude immediate still-blocked re-waits; absent denominators are **missing**, never 0%.
- A Task that was claimed from inbox and later stolen is **not a new external Task**. Do **not** add inbox-claimed Task count and steal success count to infer distinct completed work. No worker-local task origin or exact success-search cycle ratio is reconstructed unless explicitly present in the source counters.

Medians below are **medians of ten independent per-process ratios** per (workload, producer count), pooling five GC and five recycle cases *descriptively*. We independently retained the six storage-separated groups for sensitivity checks. None are ratios of independently pooled median counts.

## XPS per-Task work-acquisition pressure

| Workload | Producers | Owner-local misses / Task | Empty ingress claims / Task | Failed steal attempts / Task | Steal success / attempt | Failed / successful steal | Park checks / Task | Claimed Tasks / inbox batch |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| minimal | **1** | **1.440** | **0.959** | **2.538** | **6.95%** | **13.40** | **0.769** | **2.045** |
| minimal | **4** | **1.851** | **1.203** | **3.380** | **3.49%** | **27.69** | **1.081** | **1.551** |
| minimal | **8** | **1.881** | **1.222** | **3.446** | **3.24%** | **29.89** | **1.106** | **1.526** |
| compute-1024 | **1** | **1.200** | **0.744** | **1.594** | **15.96%** | **5.27** | **0.441** | **2.195** |
| compute-1024 | **4** | **1.626** | **0.940** | **2.392** | **8.20%** | **11.20** | **0.730** | **1.470** |
| compute-1024 | **8** | **1.704** | **1.001** | **2.582** | **7.38%** | **12.55** | **0.792** | **1.421** |

The first post-wait search is empty in **38.88%→42.24%→42.39%** of minimal runs' finished waits and **18.67%→33.54%→33.31%** of compute finished waits at 1→4→8 producers (again medians of per-process fractions). An empty first search may follow successful wakeup after a different worker already claimed the available work.

**Interpretation:** Multiple producers coincide with both **lower per-steal hit rate** and **more failed owner-local/inbox/steal searches per completed Task** in both payloads; much of the change occurs between one and four producers and then tends to plateau at eight. At four producers, on the minimal workload only ~3.5% of steal attempts find a Task, and an average successful steal is accompanied by ~28 failed steal attempts in the *same process*. This says nothing about relative duration of failed vs successful deque operations.

## Paired scaling checks

Against the one-producer combined-mode case in the **same measurement round, workload and storage policy**, twenty comparisons each for targets 4 and 8 (forty total):

| Workload | Target producers | Median Δ failed steals / Task | Median Δ owner-local misses / Task | Median Δ park checks / Task | Median Δ steal success fraction |
|---|---:|---:|---:|---:|---:|
| minimal | 4 | **+0.931** | **+0.427** | **+0.343** | **−3.54 percentage points** |
| minimal | 8 | **+0.967** | **+0.444** | **+0.354** | **−3.69 pp** |
| compute-1024 | 4 | **+0.792** | **+0.406** | **+0.284** | **−7.54 pp** |
| compute-1024 | 8 | **+0.986** | **+0.489** | **+0.351** | **−8.47 pp** |

Across **all 40** matched comparisons: failed steals/Task, owner-local misses/Task and park checks/Task **increase**, while steal success fraction and inbox batch size **decrease**. These observations are **correlated**, because several comparisons reuse the same one-producer control, so do not treat forty ratios as forty iid independent random trials.

## Performance and architecture decision

This result **strongly supports a search-coordination pressure hypothesis** but does **not** isolate CPU nanoseconds spent in steal attempts, park/wake latency, mutex wait or worker scheduling. The previous [same-source worker CPU/parking correlation](xps-worker-parking-resource-correlation-review-2026-10-13.md) showed worker voluntary context switches and CPU rising with these counts, but the profiler modifies code paths and observation schedule.

The current full-victim search visits **up to N−1 foreign queues after a local miss and an empty external inbox**; one successful steal may follow multiple failed probes, and an unsuccessful full sweep can lead to parking. Reducing search count blindly would risk missing available work or biasing worker fairness. Earlier [victim sweep correctness qualification](xps-victim-sweep-review-2026-10-11.md) had already identified a bug in the old abbreviated traversal; do **not** reintroduce it.

**Next narrow decision:** no additional XPS test is needed merely to calculate normalized acquisition event counts. Before designing one bounded algorithm experiment, use the actual full-victim code and existing victim-search trace/reference evidence to determine whether a *specific* failure pattern can be avoided without weakening full victim coverage, progress, close/join behavior or wakeup safety. If a concrete single-mechanism candidate emerges, qualify separately on DMD/LDC plus native **unprofiled** throughput/latency and negative wake/close/GC lifetime tests. Preserve the earlier waiter-aware notification A/B **negative/inconclusive result**; notifications are not an automatic optimization target.

**Final disposition:** KEEP default `freshGc` and `NotificationPolicy.always`, strongly rooted owned TaskRefs, bounded admission, full victim coverage and current generation predicate. DEFER generalized recycler, lock-free inbox, disabled notifications, forced inbox batching, spin-before-park and architecture-wide lock rewrites. Research results stay on Draft PR #35, Issue #20 open; `develop` remains unchanged.
