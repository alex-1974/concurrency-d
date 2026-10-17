# M1 P15 — Exact-M0 TaskInbox mutex acquisition and hold-time probes

**Research date:** 2026-10-13  
**Status:** compiler-qualified DMD/LDC, including optimized LDC and release. **Complete native XPS P15 archive received, inspected and documented**; precise uninstrumented lock costs and causal bottlenecks **remain unproven**. No source/production changes; no performance or `@safe` promotion.  
**Context:** [P14 full XPS event analysis](../p14_scheduler_events/evidence/xps-2026-10-13-analysis.md), [P13 multi-wave work](../p13_worker_scaling/README.md), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Research question and a strict non-goal

P14's complete XPS archive showed that a **shared TaskInbox** accepted **all 6,144 tasks** per sample and separately counted matching completion obligations, but it did **not** time any central lock path. With 4 workers and 0 compute iterations, ingress=8 also generated more failed steals, parked workers and retries than ingress=64/256. These are associations; the exact cycle cost of `trySubmit`, `completeOne`, inbox draining and wake handling remains **unknown**.

P15 measures **how many times the five nonblocking critical sections run, their sampled mutex-acquisition intervals, and the elapsed time spent in the original critical section until the release-time probe**. The instrumentation is deliberately invasive. Its timings are **NOT the uninstrumented scheduler's true mutex wait/hold duration**, and cannot establish a causal hotspot without independent calibration/confirmation.

P15 **does not** change M0's admitted-task obligations, queue publication, condition/wake generation, worker-deque semantics, `closeAndJoin`, error policy or task representation. It does not implement the proposed batching/completion optimization.

## Exact-source generator and matched control

[Generator: `m1_p15_make_mutex_probe.py`](../../../../tools/research/m1_p15_make_mutex_probe.py) checks the source Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`** of [production `submission_pool.d`](../../../../source/concurrency/internal/submission_pool.d). It rejects changed source and ambiguous source anchors. Only then does it create a separately named **`concurrency.research.m1_p15_pool`** module in the ignored/generated research directory.

[Generator: `m1_p15_make_fixture.py`](../../../../tools/research/m1_p15_make_fixture.py) checks the independently pinned P13 source blobs (`3852e8788757b62c5000ad55565359d6a20a78c1` for the kernel and `723de6bf76ac838b10de4b3f1cb901315a5ced38` for the driver). It creates the same P13 worker-wave, oracle and randomized workload in two compile-time variants:

- **Control**: imports the untouched production M0 `SubmissionWorkerPool`. Its newly added P15 timing CSV fields are **all zero**.
- **Timed**: imports the exact-source research copy, enables `-version=P15Timed`, and samples the same worker/ingress/compute/wave paths. Both source variants expose the same `TaskRef` scheduling semantics, output arrays, input sequence, checkpoint cadence and native join protocol.

The research DUB [manifest](dub.sdl) preserves root `concurrency-d` and real `containers-d 0.2.0` package dependencies. No `source/`, production DUB flag, data layout, or other repository has been modified. Generated source is **not committed**.

## The five measured sites

| CSV prefix | Original M0 critical-section method | Expected use |
|---|---|---|
| `submit` | `TaskInbox.trySubmit` | Every accepted/full/closed producer attempt under the common inbox mutex |
| `batch` | `TaskInbox.takeBatch` | Worker claims up to eight tasks from the shared FIFO |
| `complete` | `TaskInbox.completeOne` | **One central inbox mutex acquisition per completed task** |
| `generation` | `TaskInbox.wakeGeneration` | Captures generation before external local/steal search |
| `local_signal` | `TaskInbox.announceLocalWork` | Notifies thieves when a worker deposits local work |

For every site P15 records `calls`, total observed `wait_ns`, total observed `hold_ns`, maximum observed `wait_ns`, and maximum observed `hold_ns`. The count and timing fields are stored behind the **existing TaskInbox mutex** and are read **only after a successful native join**.

**The condition-variable method `parkUnlessChanged` is intentionally NOT timed as mutex hold:** `Condition.wait` releases and reacquires the lock, so a naive enclosing stopwatch would charge time **asleep** to the mutex critical section. P14 already counts actual wait entries, and P15 keeps that as a separate research question.

### How to interpret the timing fields

The implementation captures `MonoTime.currTime.ticks`:

1. just before entering `synchronized(_mutex)`;
2. just **after** acquiring the lock;
3. in a `scope(exit)` observer while still inside the lock, **before** per-site statistics are fully updated.

The reported `wait_ns` is **acquisition interval elapsed**: it includes surrounding clock-call and scheduling overhead, not just time blocked on the Mutex's internal primitive. The reported `hold_ns` runs from the acquired timestamp until the scope-exit probe; it includes extra time spent reading clocks but **does not include all instrument bookkeeping or the final mutex release**. These are **perturbed timer-based proxies**, not unbiased lock durations. The stats update itself increases lock hold time **after** the final recorded timestamp; this also perturbs other threads' measured waits. The probes do not provide a calibrated constant that can safely be subtracted.

Aggregated wait times from different threads can overlap and exceed the entire measured wave's wall-clock time. Do not interpret a ratio `sum(wait_ns) / waves_ns` as exclusive CPU cost or add these values to approximate a task's critical path.

## Correctness gates and diagnostic use

The runner and CSV checker validate:

- same randomized `phase/round/order/seed/workers/iterations/ingress/count/waves` and checked checksum for each control/timed row;
- same result oracle and accepted/completed counts in the *original P13 workload* under both modes;
- zero P15 timing fields in control; no negative counts/timing or maxima larger than corresponding sums in trace;
- `submit.calls = accepted + retries = count × waves + producer retries`;
- `complete.calls = count × waves`, and at least one inbox `takeBatch` call in every timed run;
- DMD **2.111.0**, LDC **1.41.0** correctness; an additional LDC **debug `-O3`** asserts-on build; and an LDC whole-package **release** build with explicitly checked result/oracle work;
- short six-case smoke and an additional **45-case native-profile correctness preflight** with small task counts, on both compilers.

**[P15 CI #38448860940](https://github.com/alex-1974/concurrency-d/actions/runs/38448860940) PASS DMD and LDC**, including P01–P14 prior tests. Small shared-CI sample times fluctuate substantially; they are **not** architecture evidence. For illustration only, one LDC release CI set at ingress 64 reported **4-worker median `complete` acquisition intervals around 949–1,017 ns per call**, but **4-worker `complete` hold probes around 47–49 ns per call**. Timed/control ratios for short tasks were often **2× or worse**. The large perturbation makes naive claims that the unmodified M0 intrinsically holds a lock for 50 ns or waits 1 µs **invalid**. CI hosts are not matched native XPS environments.

## Native XPS evidence protocol

The [foreground P15 XPS runner](../../../../tools/research/m1_p15_xps.sh) uses the same native full P13 matrix as P14: **1/2/4 workers, 0/8/32/128/512 unsigned iterations, ingress 8/64/256, 2,048 tasks per wave × three waves**. Each of three default sessions runs control/timed as separate processes in alternating whole-process order, with equal seeds, two warm-up full sweeps and seven measured sweeps. The script restricts the **process** affinity to four allowed CPUs from distinct physical cores and records CPU topology/affinity, compiler/commit, original output and optional pre/post `sensors` snapshots; it does not claim per-worker pinning or continuous frequency/thermal monitoring.

Run in a **separate clean research worktree**:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin research/m1-task-lifetime-boundaries
git worktree add --detach ../concurrency-d-p15 \
    origin/research/m1-task-lifetime-boundaries
cd ../concurrency-d-p15
bash tools/research/m1_p15_xps.sh ldc2 /tmp/p15-xps-2026-10-13
```

Output: `/tmp/p15-xps-2026-10-13.tar.gz` containing `manifest.txt`, control/timed raw logs and normalized CSV files, session comparison diagnostics and machine snapshots. **Review manifests/raw logs for local user/host/path information before publication.** The experiment is foreground-only. The native XPS P15 archive was subsequently provided and analyzed; the complete results and limits are recorded in the evidence section below.

## Disposition

**KEEP:** exact-source and exact-work lock timing experiment; separate control; tested timing-site invocation conservation; diagnostic DMD/LDC/release coverage; and native evidence capture.

**DEFER:** identification of a causal lock bottleneck, conversion of probe wait to uninstrumented mutex contention costs, completion batching/lock-free atomic changes, worker-count/ingress defaults, a C++ performance comparison or an arbitrary public `@safe TaskScope`. P06/P07 native failing-join/start-after-launch concerns remain outstanding; the research batch's `@system` plus fail-stop-on-uncertain-join boundary is unchanged.

**P16 candidates after native P15:** either a *separately calibrated lower-impact lock-wait experiment* (clock microcost, high-sample latency distributions, optional OS profiling on uninstrumented M0) or a single isolated **matched-lifetime completion policy** that preserves all final-shutdown and task-completion predicates. Do **not** replace mutex accounting merely on the basis of self-instrumented timings.


## Native Dell-XPS evidence received — 2026-10-13

**[Full native P15 archive integrity, unchanged-control scaling and invasive timed-lock analysis](evidence/xps-2026-10-13-analysis.md).** The original user's `p15-xps-2026-10-13.tar.gz` has SHA-256 `5423ea7385445f5487fa289b24a59fe5f3e0719ae3a2200e41f845376c2910d0` and was produced at source commit **`fb0147d6f44183b0eae7e3ccfbc48cf4c7e0c734`** using LDC 1.41.0 release on Dell XPS i7-9750H. CPU affinity 0–3 corresponds to four distinct physical cores; it is not per-worker pinning. The full archive was **not published** to GitHub because manifest/raw logs include local system identifiers.

**Archive verification:** three sessions × 45 configurations × 2 warm-up + 7 measured sweeps × 2 modes: **2,430 rows**, of which **945 matched control and 945 matched timed** (540 warm-ups). Equal randomized case order and checksum in each paired control/timed row, no missing/duplicate configurations, exact stage-sum accounting, zero control timings, `submit.calls=6144+retries`, and `complete.calls=6144` in *every timed sample* all PASS.

**Only UNINSTRUMENTED control should be used for scaling:** within-sweep 4w/2w `waves_ns` ratio medians across 63 comparisons per kernel are **1.696× at 0**, **1.612× at 8**, **1.501× at 32**, **1.176× at 128** and **0.912× at 512** iterations. Four workers win **0/0/0/9/46** of the 63 cases respectively. This reproduces P13/P14's task-granularity crossover.

**The TIMED research clone shows considerable self-perturbation:** paired `timed/control` median **2.145×** over 945 samples; at 0 iterations **2.747×**, at 512 **1.732×**. With 6,144 zero-iteration tasks and ingress 64, observed **completion acquisition/hold intervals per call** had medians **781/97 ns** (1w), **964/87 ns** (2w), **2662/107 ns** (4w). The larger measured acquisition interval at 4w is consistent with concurrency pressure on the shared inbox mutex, but **is not its uninstrumented waiting time**. The probe reads clocks and updates statistics inside the critical section; aggregated wait intervals overlap, and measured hold times exclude final observer bookkeeping and unlock.

**Decision:** KEEP the repeated-workload control scaling and source-verified, internally consistent lock timing evidence; **DEFER** attributing a production percentage or nanosecond bottleneck, rewriting `completeOne`, tuning queues/stealing/worker activation, or public `@safe` promotion. The next P16 research question should first calibrate/limit instrumentation and isolate one mechanism while preserving per-task completion, lost-wake protection, shutdown/join obligations and actual native failures.
