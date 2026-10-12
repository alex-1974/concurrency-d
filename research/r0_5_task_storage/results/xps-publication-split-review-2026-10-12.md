# R0.5 XPS — Publication split: GC-root append versus inbox submit (2026-10-12)

**Research conclusion:** In the opted-in full-victim R0.5 mixed minimal workload, **the inbox submission call dominates the measured publication bracket**: median **2,691 ns/accepted task** versus **165 ns** for adding a strong GC root. Across the 60 instrumented cases the median within-run inbox/publish ratio is **89.41%** (range 83.18–91.51%), while root/publish is **5.93%** (range 3.36–12.53%). This is a **probe-inclusive composite measurement**, not proof that the nested inbox mutex, queue update, or `Condition.notify` *individually* accounts for that cost. **KEEP `freshGc` default; investigate inside the inbox next, without changing synchronization or ownership semantics.**

## Original evidence and exact source revision

- Original user-supplied `r05-xps-publication-split.tar.gz`; SHA-256 **`fe2d3ccbff44d828869b678f7acb8cbf0c1b351ade08322b61c1f62fe30eb7c9`**. Its five original first-level evidence files are `raw.csv`, `pairs.csv`, `diagnostics.csv`, `summary.csv`, `environment.txt`. The uploaded tar also contains **a nested copy of a similarly named `.tar.gz` file**; it was deliberately **not** interpreted as an independent second dataset. The five evidence files are not rewritten or committed to Git.
- Git source recorded in `environment.txt`: **`46083df16ec8a73fcc89a5131270b85c9ea5a105`**, grandfathered research branch `perf/r05-owned-task-pipeline`, `git status --short --untracked-files=no` empty. GitHub source at that ref confirms opt-in timing of `_retained ~= RetainedTask(...)` and `_pool.trySubmit(...)` inside the aggregate `publish` bracket. A clean *tracked* status does not establish that no untracked files existed.
- Dell XPS Intel **i7-9750H** (6 cores/12 logical threads), Linux 6.17.0-22-generic x86-64, glibc 2.43; **LDC 1.41.0** / LLVM 19.1.7 / DUB 1.40.0; governor **powersave**. `lscpu` CPU-scaling snapshot **89%** is **not** measured workload clock average. CPU affinity, controlled thermals, competing processes and energy state were not traced.
- The experimental R0.5 scheduler uses the **full N-candidate, self-skipping victim traversal**, aligned with the *specific mechanism* merged into `develop` via production PR #37 (`7af4409a2e09a303dfbc6c54033d28c92eb67581`). This does **not** mean R0.5 OwnedTask and production M0 are equivalent executors.
- Matrix: **5 rounds × 3 producer counts (1, 4, 8) × 2 retention budgets (8, 512) × 2 storage policies (`freshGc`/`recycleTyped`) × 2 profile modes (`off`/`on`) = 120 independent child processes**, 4 workers, 30,000 mixed minimal typed/GC-visible/void tasks each, shared execution atomic, **3.6 million completed tasks**. Profiling remains a compile-time-gated research feature (`R05AdmissionStageProbe`). `off` uses the uninstrumented submission path; `on` additionally runs existing admission wait/hold/stage probes and the two new substage timers.

## Independent source-data checks

Original first-level CSVs were parsed afresh, not treated as precomputed proof:

- `raw.csv` **120 unique** case keys (round, producers, budget, profile, policy), all expected combinations, `completed=tasks=30,000` in every child, `fresh_nodes + reused_nodes=30,000`, `observed_handles=1,765` for every child.
- `pairs.csv` **60** matching same-round policy pairs. All `recycle/GC` ratios recalculated to numerical equality with the original raw rates.
- `diagnostics.csv` **60** profiled GC/recycle rows. Each substage ns/event, stage/publish ratio and mutex wait/hold average recomputes to the original cumulative raw counters.
- `summary.csv` **12** groups. Five pairs per group, every grouped paired median and win count recalculated correctly.
- For all 60 profile-on rows: `accepted=30,000`, `gate_count=attempts=accepted+retention_full+ingress_full`, `cell_count=node_count=publish_count=root_append_count=inbox_submit_count=accepted`, `yields=retention_full+ingress_full`, and `root_append_ns+inbox_submit_ns < publish_ns`. Profile-off rows have these counters blank.
- All 60 profiled rows report **`ingress_full=0`**. Their combined **400** `retention_full` retries occur in only 16 rows (max 88 retries in one child). No observed queue-capacity rejection was recorded for this workload.
- The child benchmark continues to assert exact accepted/completed/executed tasks, observed typed results, void-task work and full drain. It is **not** a general proof of move-only destructor/GC lifetime or `@safe` cross-thread captures.

## Substage results: inbox submit overwhelms GC-root bookkeeping

Five-run medians per scenario for the two instrumented substage times (**ns per accepted task**, computed separately per run then median):

| Producers | Budget | Policy | GC root append | Inbox submit |
|---:|---:|---|---:|---:|
| 1 | 8 | GC | 137 | 2,000 |
| 1 | 8 | recycle | 178 | 2,098 |
| 1 | 512 | GC | 84 | 1,929 |
| 1 | 512 | recycle | 110 | 2,307 |
| 4 | 8 | GC | 330 | 2,725 |
| 4 | 8 | recycle | 304 | 2,676 |
| 4 | 512 | GC | 158 | 2,678 |
| 4 | 512 | recycle | 140 | 2,772 |
| 8 | 8 | GC | 329 | 2,746 |
| 8 | 8 | recycle | 317 | 2,759 |
| 8 | 512 | GC | 187 | 2,789 |
| 8 | 512 | recycle | 161 | 2,803 |

Across **all 60 instrumented runs**, descriptive independent medians:
- Root append **164.8 ns/accepted task** (72.1–419.0 ns).
- Inbox submit **2,690.6 ns/accepted task** (1,816.6–2,998.8 ns).
- Aggregate publish **3,074.4 ns/accepted task** (1,992.5–3,486.6 ns).
- Within-run `inbox_submit_ns/publish_ns` **0.8941**, min–max **0.8318–0.9151**; `root_append_ns/publish_ns` **0.0593**, min–max **0.0336–0.1253**.
- Within-run `(root_append_ns+inbox_submit_ns)/publish_ns` **0.9532** median (0.9464–0.9572), reflecting extra clock reads, counter updates and instruction gaps in the aggregate bracket. **These ratios do not give unbiased real execution cost shares.**

The patterns favor inbox submission for both policies and all producer/budget groups; even the largest observed root fraction remains 12.53%. More producer contention mildly raises instrumented inbox time (~2.1µs at 1 producer to ~2.8µs at 8 producers), but this is only a cross-condition *descriptive* comparison.

**Exact code boundary:** `_pool.trySubmit` delegates to `_inbox.trySubmit`. Its implementation acquires a *second* inbox mutex under the outer admission mutex, checks closure/capacity, writes a `TaskRef` slot, adjusts occupancy/counters/generation, and for `NotificationPolicy.always` may call the condition-variable notify. **This experiment does not separate inbox mutex wait, time holding the inbox mutex, slot/generation work or the notify call.** It does not justify switching locks, changing the wake predicate, removing notifications, or asserting that a particular operation costs 2–3µs.

## Producer admission wait and uninstrumented throughput

Medians across **20 heterogeneous instrumented policy × budget × round cases per producer count**; not a single homogeneous trial:

| Producers | Inbox ns/accepted | Outer admission mutex wait ns/attempt | Outer admission mutex hold ns/attempt |
|---:|---:|---:|---:|
| 1 | **2,077** | **44.5** | **3,755** |
| 4 | **2,700** | **17,755** | **5,083** |
| 8 | **2,779** | **42,556** | **5,189** |

The strong increase in measured mutex acquisition wait is consistent with producer contention and/or scheduling perturbation, **not direct proof that either mutex is the unique bottleneck**. There were zero inbox-full retries in the instrumented data, and very few retention-full retries.

The authoritative **uninstrumented** paired `recycleTyped/freshGc` throughput medians, five paired rounds each:

| Producers | Budget | Off median recycle/GC | Recycle wins /5 |
|---:|---:|---:|---:|
| 1 | 8 | 0.9874× | 2 |
| 1 | 512 | 0.8914× | 2 |
| 4 | 8 | 0.9947× | 2 |
| 4 | 512 | 1.0073× | 3 |
| 8 | 8 | 0.9885× | 1 |
| 8 | 512 | 1.0093× | 3 |

Across all **30 `off` pairs**, descriptive median ratio **0.98929×**, recycling wins **13/30**; the 30 profiled `on` ratios have median **0.97141×** and **12/30** wins. In particular 1 producer / budget 512 spans **0.6324×–1.7629×** in `off` cases, so its 0.8914× median is **not** a convincing isolated 11% systematic penalty. Raw `on` versus `off` throughput cannot be subtracted to obtain profiler-free operation costs. Previous native 30k and 100k campaigns have different instrumentation, run history and conditions and **must not be pooled** as equivalent replicates.

### Memory observations

Fresh per-process `wait4` RSS is effectively flat: **119/120 rows at 19,004 KiB** and a single `off` GC row at 18,856 KiB. This study **cannot resolve** the peak-RSS benefit seen in the earlier 100k-task archive. The captured `producer_gc_bytes` are producer-thread GC allocation only, not whole-process or stage-specific memory usage.

## Engineering disposition and narrow next experiment

**KEEP:** `freshGc` normal/default policy and the original safe publication ordering: record strongly GC-rooted **before** inbox publication, full-victim traversal, bounded rejection-before-allocation, locked admission/close, generation-based wake logic, and separate experimental R0.5 evidence.

**DO NOT ADOPT YET:** rewriting the retained-root data structure, a type-indexed recycler, removing either lock, a lock-free inbox, altered `Condition.notify()` policy, moving allocation outside the mutex, or promoting all of Draft PR #35. This dataset identifies **where to measure next**, not a proven replacement or performance gain.

**Next discriminating measurement:** add an *opt-in inbox-local probe* around **(1) inbox mutex acquisition wait** and **(2) work after lock acquisition**, and, *only if justified*, **(3) slot/counters/generation vs `Condition.notify()`**. For a correctness-safe boundary, measure by source-bracketing the original `synchronized(_mutex)` without changing lock acquisition/release or predicate, recording per-inbox counters only under the existing mutex and reading them after full join. Never introduce unprotected reads or extra notifications. Maintain a distinct uninstrumented full-victim build with identical consumer/capacity/notification settings. Validate DMD 2.111 x86 and LDC 1.41 x86/native ARM64; use new paired native Dell XPS results before treating any scheduler architecture as optimizable.

**State:** grandfathered research PR #35 remains Draft/unmerged and Issue #20 open. No writing to `develop` or other repositories. Prior raw tar, results and commits preserved, not rewritten.
