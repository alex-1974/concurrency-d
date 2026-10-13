# R0.5 — Native Dell XPS same-source admission / worker acquisition cost study (2026-10-13)

**Result and decision:** With increasing producer count (1 → 4 → 8), *the same profiled child-process runs* show **sharply higher outer Admission mutex elapsed wait, higher actual producer and worker thread CPU, more voluntary context switches, more condition waits and more failed steal attempts per completed Task**. An **important large observer effect** exists: enabling AdmissionProbe clocks on an **identical joint binary** reduces within-round throughput in 29/30 matched comparisons, with descriptive pooled median `joint_on/joint_off=0.7548×`. Therefore **do not add producer mutex wall waits, worker CPU, or steal event counts as a causal additive cost budget, and do not promote a scheduler change** from these data. Default **`freshGc`** and **`NotificationPolicy.always`** remain KEEP; full foreign-victim coverage, GC strong-root publication and close/wake/TaskRef semantics remain unchanged.

## Original evidence and identity

- User-uploaded original **`r05-xps-joint-cost.tar.gz`**, SHA-256 **`f10befbc8271221c10807e1b9a1120553778f460b743884bf707431cb2f6be16`**. Exactly six regular source evidence files: `raw.csv`, `worker.csv`, `stages.csv`, `pairs.csv`, `summary.csv`, `environment.txt`. Raw archive preserved without rewrite or committing large artifacts.
- Measured grandfathered research **HEAD `84fcb47b8e0b7b31725672ddc49fee17b29577ba`**, not the later documentation-only report commit. LDC **1.41.0**, LLVM **19.1.7**, DMD frontend **2.111.0**, DUB **1.40.0**; Dell XPS Intel **i7-9750H**, 6 cores / 12 logical threads, Linux **6.17.0-22-generic**, `powersave`. One instantaneous `lscpu` scaling snapshot shows **86%**, *not* a stable frequency or thermal trace; no per-run affinity/background/energy evidence.
- Four version/measurement modes use the same full-victim R0.5 research implementation, four workers, budget512, **GC only**, shared benchmark counter, fixed mixed typed/GC-visible/void Tasks, `NotificationPolicy.always`. Source is not the separate M0 production executor.
  - `plain`: unchanged unprofiled release binary SHA256 **`e2d2200b7374ae2497c4660d0737fe321d24f92b4902528f32bd6f2ade76d964`**.
  - `worker`: existing worker-resource version (thread-boundary `getrusage` + existing runtime parking counters), SHA256 **`8138e0cb74d208d04957c3831a9c4c61a4c5da329d3123d6fb293485bf788701`**.
  - `joint_off`: jointly versioned full-victim worker-resource + AdmissionStageProbe executable, external `instrumentation=off`, parking counters ON, SHA256 **`46229b91504d1f6dc0a404e69b6b1fd2dfddea8d338a10bb5b8fd9ee8bbe3084`**.
  - `joint_on`: **exact same executable SHA** as `joint_off`; admission `instrumentation=on`, parking ON. Contains Admission mutex stage/cell/node/publication wall-clock timers, **not** the additional `R05InboxSubmitProbe` per-submission clocks (absent from this binary).
- Experiment: 5 rounds × minimal/compute-1024 × producers 1/4/8 × `freshGc` × four modes = **120 isolated child processes × 30,000 completed Tasks = 3.6 million Tasks**. 90 worker-measured processes × four workers = **360 worker resource rows**, 30 Admission stage processes, 30 same-round matched four-mode comparisons and 6 scenario summaries.

## Independent integrity audit of all original CSVs

The archived source CSVs were parsed and cross-reconciled directly, **not** by trusting `summary.csv`:

1. `raw.csv`: exactly 120 unique (round, workload, producer count, GC policy, mode) keys, no missing factorial cases. Every case has four workers, budget512, shared counter, 30,000 completed Tasks, **30,000 fresh nodes / zero recycled nodes**, 1,765 observed typed handles and valid workload checksum (`minimal=0`, `compute-1024=21334545774983`). End-to-end wall time is longer than the benchmark's internal timed interval in each case. All modes use the expected binary hash; `joint_off/joint_on` share one exact binary.
2. `worker.csv`: exactly 360 distinct (round, workload, producers, policy, mode, worker index) records. Four indices 0..3 in each worker/joint_off/joint_on process; none in plain. Each resource record has `cpu_user_us + cpu_system_us == worker_cpu_us`, and all four summed worker CPU and voluntary-switch counts exactly equal the raw process worker totals.
3. `stages.csv`: exactly 30 unique `joint_on` keys; every stage satisfies `attempts=accepted+retention_full+ingress_full`, `gateCount=attempts`, and `cell=node=publish=root_append=inbox_submit=accepted=30,000`. **All 30 cases have zero retention-full and zero ingress-full rejection** (no admission retry due to full buffers), but outer mutex waiting is still substantial at 4/8 producers. Nested root-append and inbox-submit elapsed bracket totals do not exceed composite publish elapsed brackets. Every raw admission wait/hold and stage per-task value independently reproduces from its corresponding integer nanosecond sum and correct denominator.
4. `pairs.csv`: all 30 four-mode same-round ratios rederived exactly from raw throughput; `summary.csv`: all six five-round medians rederived for every field, no missing groups.
5. **All 120 process RSS high-water entries equal 25,976 KiB**, a constant that does not qualify a GC/memory improvement. No `perf stat`, cycles, instructions, kernel futex trace or wake-to-run latency was collected.

The original experimental runner and canonical [protocol](../r05-same-source-cost-attribution-protocol.md) remain the executable recipe. The research source and native archive identity are fixed above; no D scheduler source code was changed for this review.

## A. Original Admission stage wall-time indicators (JOINT_ON only)

**Each cell is a median over five independent 30,000-Task `joint_on` processes**, for the given workload and producer count. Admission mutex *wait* covers time before lock acquisition including possible descheduling. Hold encloses the existing executor critical section, with measurement overhead. Publish comprises nested root-append and inner inbox submission.

| Workload | Producers | Admission mutex wait ns / attempt | Mutex hold ns / attempt | Nested `_pool.trySubmit` ns / accepted Task | Publish ns / Task |
|---|---:|---:|---:|---:|---:|
| minimal | 1 | **55.8** | **3,933.6** | **2,187.0** | **2,423.3** |
| minimal | 4 | **17,452.4** | **5,040.3** | **2,776.7** | **3,085.4** |
| minimal | 8 | **43,076.1** | **5,159.9** | **2,809.2** | **3,145.0** |
| compute-1024 | 1 | **41.5** | **2,737.8** | **1,385.9** | **1,579.4** |
| compute-1024 | 4 | **16,583.2** | **4,516.3** | **2,464.9** | **2,766.7** |
| compute-1024 | 8 | **40,409.9** | **4,766.1** | **2,517.8** | **2,852.2** |

For example, eight producers in compute spend a total of ~40µs of **producer-side elapsed wait per attempt** while worker and producer threads progress concurrently. This exceeds the *mean wall time per completed Task* implied by aggregate task throughput (~6.1µs at 164,599 Tasks/s) because concurrent producer waits **overlap each other and other threads**. **It is not a contradiction** and specifically demonstrates why these waiting times cannot be summed into a one-Task latency budget or CPU percentages.

All admitted samples succeeded on their first capacity/retention gate attempt, so `admission_wait_ns_per_attempt == admission_wait_ns_per_accepted` in this corpus. It does **not** imply every Task encountered zero contention; it means no full-buffer rejection/retry was measured.

## B. Worker and producer CPU/switches and acquisition events, JOINT_ON only

**Median of five processes per group**; each metric median is computed separately and group median totals therefore need not add up exactly.

| Workload | Producers | 4-worker CPU ms / 30k | Producer CPU ms / 30k | Worker voluntary switches / 30k | Producer voluntary switches / 30k | Condition waits / Task | Failed steals / Task | Inbox Tasks / batch |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| minimal | 1 | **287.2** | **122.5** | **48,738** | **3,694** | **0.861** | **3.374** | **1.595** |
| minimal | 4 | **344.4** | **266.8** | **61,532** | **30,441** | **1.020** | **3.918** | **1.386** |
| minimal | 8 | **356.1** | **275.5** | **62,110** | **30,825** | **1.025** | **3.956** | **1.391** |
| compute-1024 | 1 | **249.5** | **90.1** | **28,877** | **3,008** | **0.557** | **2.236** | **1.582** |
| compute-1024 | 4 | **368.2** | **253.9** | **53,343** | **27,731** | **0.866** | **3.402** | **1.273** |
| compute-1024 | 8 | **390.6** | **265.4** | **54,214** | **28,115** | **0.867** | **3.453** | **1.290** |

The increase occurs **within the same joint_on profiles**, resolving an earlier concern that native admission timing and worker CPU/parking counts came from completely separate source revisions. It **does not remove profiler observation effects**.

### Same-round producer-scaling increments

For each workload, compare the same round/GC policy's `joint_on` run at 4 or 8 producers with its 1-producer `joint_on` run. Median of **five individual differences**:

| Workload | Producers vs 1 | Δ admission wait ns / attempt | Δ producer CPU ms / 30k | Δ worker CPU ms / 30k | Δ producer voluntary | Δ worker voluntary | Δ failed steals / Task |
|---|---:|---:|---:|---:|---:|---:|---:|
| minimal | 4 | **+17,386.6** | **+143.3** | **+67.3** | **+26,814** | **+12,146** | **+0.537** |
| minimal | 8 | **+43,020.3** | **+153.0** | **+85.1** | **+26,987** | **+13,372** | **+0.625** |
| compute-1024 | 4 | **+16,537.8** | **+151.6** | **+102.3** | **+24,680** | **+24,463** | **+1.166** |
| compute-1024 | 8 | **+40,370.5** | **+177.0** | **+144.3** | **+25,077** | **+24,686** | **+1.191** |

**All 20** (five rounds × two workloads × two target producer counts) matched `joint_on` differences are **positive** for admission wait/attempt, producer and worker CPU, producer and worker voluntary switches and failed steals/Task. Worker condition waits/Task also rise in all 20. These are **correlated comparisons** sharing one-producer control runs, not twenty iid causal trials or proof of a particular lock's CPU cost.

## C. Observer effect is large and measurable

Within the **same** joint executable binary SHA `46229b9...`, switching its external runtime AdmissionProbe from `off` to `on` changes observed throughput:

| Workload | Producers | Median `plain` Tasks/s | Median `joint_off` Tasks/s | Median `joint_on` Tasks/s | **Paired median `joint_on/joint_off`** |
|---|---:|---:|---:|---:|---:|
| minimal | 1 | 356,393 | 347,719 | 223,930 | **0.630×** |
| minimal | 4 | 195,863 | 197,471 | 157,300 | **0.801×** |
| minimal | 8 | 185,811 | 192,532 | 154,508 | **0.789×** |
| compute-1024 | 1 | 343,615 | 347,451 | 295,330 | **0.765×** |
| compute-1024 | 4 | 232,096 | 235,798 | 172,043 | **0.747×** |
| compute-1024 | 8 | 220,490 | 225,922 | 164,599 | **0.748×** |

**29/30** within-round `joint_on/joint_off` ratios are **below 1**; one compute/1p is slightly above 1 (`1.0063×`). Descriptive pooled median **0.75479×**, range **0.58840–1.00629×**; **do not claim a precisely measured 24.5% production overhead**, because even this same-binary A/B reflects changes in instrumentation, thread scheduling and clock environment. Its material direction strongly establishes **intrusive observer effect**.

The `worker` and `joint_off` (and `plain`) executables have different compile-time versions and **must not** be described as codegen-identical even when runtime admission profiling is OFF. Their respective pairs are only controls for codegen/probe variation, not algorithmic speedups.

The **uninstrumented `plain`** per-round throughput ratios with four/eight producers versus one remain **below one in every matched pair**:
- minimal median 4p/1p **0.575×**, 8p/1p **0.533×**;
- compute-1024 median 4p/1p **0.691×**, 8p/1p **0.610×**.

This is a more defensible check of **persistent negative producer scaling** than using the absolute values of `joint_on`.

## D. Implications and next narrow investigation

**Established:**
- Strong outer admission *elapsed mutex waiting* develops with additional producers, despite zero full capacity/retry rejections.
- Actual producer and worker CPU and voluntary context switching rise together with steal failures and condition waits when measured in the *same* versioned `joint_on` process.
- An observed AdmissionProbe slowdown is substantial. The highest ns/Task numbers are **not** unprofiled baseline CPU cost estimators. In particular, no `notify()` duration or worker `steal()` timing exists in this joint-on archive, since the additional inbox stopwatch build was intentionally omitted.
- Workload and runtime mode materially change these quantities; previous XPS campaigns at different source/binary SHA, counter settings and power snapshot remain *context*, not extra rounds.

**Not established:** which lock or scheduling interaction consumes most *unprofiled CPU*; exact CPU cycles per failed steal, condition wait or notify; whether outer admission lock can be shortened while preserving rejection-before-allocation, GC root-before-publication, exact TaskRef lifetime and shutdown race safety; or a speedup from an alternate queue/notification mechanism.

**Suggested next research gate:** do a *code-level lifetime and mutex-order audit* of `OwnedTaskExecutor.submitImpl` and its existing `_pool.hasIngressCapacity()`, root append and `_pool.trySubmit()` sequence. Identify **one candidate operation** that might safely be computed before the admission mutex **without violating** closed/full rejection-before-allocation, capture lifetime and publication rooting, and without moving an observable task side effect across the linearization point. If no such operation is semantically safe, record the negative result rather than implementing a risky shortcut. In parallel, use pre-existing worker counts to model worker coordination, without inventing nanosecond cost per steal. Any candidate requires a *single-mechanism, fully equivalent uninstrumented* native LDC throughput and low-arrival wake-tail A/B, DMD+LDC correctness and GC-root/move/close stress gates. **Do not** start by suppressing notifications (prior native waiterAware negative/inconclusive evidence) or rotating victim order (already native-tested no stable advantage).

**KEEP** default `freshGc`, `NotificationPolicy.always`, complete foreign victim traversal, bounded admission, root-before-publish, close/join and wake-generation predicate. **DEFER** recycler promotion, lock-free inbox, blind spin-before-park, forced batching, no-notify and broad admission restructuring. Grandfathered Draft PR #35 and Issue #20 remain open; `develop`, `main` and other workspace repositories unchanged.
