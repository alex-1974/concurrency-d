# M1 P13 — Worker-count scaling on the unchanged M0 work-stealing pool

**Date:** 2026-10-13  
**Status:** working DMD/LDC research harness; **P13 summary-level native XPS evidence received**, with full original manifest/per-sweep raw archive **still pending**.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Input evidence:** [P12 independently reviewed XPS data](../p12_matched_pool/evidence/xps-2026-10-13-analysis.md).

## Why P13 exists

The P12 matched real-M0 benchmark on the Dell XPS 15, i7-9750H (6 cores / 12 threads) showed an **apparent four-worker regression** for short scalar jobs. On 16,384 jobs with stack records, P12's independent whole-batch medians were **4.725 / 4.134 / 6.903 ms** at 1 / 2 / 4 workers, respectively. Its whole-batch stopwatch, however, INCLUDED storage setup, native Thread creation and native join on every single batch. CPU affinity, in-run frequency/temperature and run-order independence were also uncontrolled. Those measurements do not isolate the scheduler or prove a bug.

P13 is a **new, isolated research experiment**, not a rewrite of P12 and not a change to the production scheduler. It asks whether **increasing the worker count from 2 to 4** still raises per-wave elapsed time when: (a) the same real M0 SubmissionWorkerPool remains alive over multiple waves, (b) all worker counts do precisely equivalent integer work and retain all task storage until native join, (c) different task sizes and ingress capacities are crossed, and (d) the target XPS experiment binds work to **distinct physical cores** and randomizes the complete comparison order.

## Exact running implementation

The P13 [research package](dub.sdl) imports the **unchanged** production `TaskRef`, `SubmissionWorkerPool` and `containers-d 0.2.0` WorkStealingDeque. The [kernel](concurrency/research/m1_scaling_kernel.d) is `@system`, with a header-first fixed-address record, input/output `uint`, runtime iteration count and an atomic per-wave return counter. There is **no dynamic delegate/captured user context**, extra virtual layer or public `@safe` entrypoint.

**Each measured configuration:**

1. Allocate and initialize a fresh GC-managed array of `count × waves` typed records. All slots are distinct, none are moved or reused. The same allocation/representation is used for 1, 2 and 4 workers.
2. Start the actual M0 pool with `workers` = 1, 2 or 4, `ingress` = 8, 64 or 256.
3. Submit `count` tasks as one wave. Every task executes exactly the same deterministic integer kernel for **0 / 8 / 32 / 128 / 512 iterations**, depending on that configuration. Publication retries on `SubmissionResult.full` and records the retry count; no tasks are silently dropped.
4. Wait for the *real M0 afterExecution callback* to signal that all of this wave's dispatched records were returned. This permits submitting the next wave **without creating new native workers**. Crucially, **no record is freed or republished** at this stage; even returned records and the stack-resident counter remain alive until the final successful native joins.
5. Repeat `waves` times on the **same running pool**. Only then call `closeAndJoin()`. Keep all records rooted through that native lifetime barrier. If the real M0 join throws on an uncertain native state, the P13 **research harness aborts** rather than unwinding caller-owned TaskRefs.
6. Post-join check that `accepted == completed == count × waves`, each task has its atomic returned marker and the exact expected input/independent sequential oracle result. Sum the output to an observed `ulong` checksum and reject any mismatch with a regular `Exception`, including in LDC release mode.

**Recorded per configuration:** record preparation/allocation ns, native worker-pool creation ns, **waves_ns** (only submissions, backpressure and full per-wave completion while workers are alive), native join ns, verification ns, total ns, producer retries, M0 `parkCount` and checksum. `waves_ns` is the primary scaling indicator but **not pure execution-kernel ns**: it includes admission, FIFO/deque work, wake/park and atomics. Work-steal counts themselves are not instrumented; P11's prior deterministic steal proof cannot be construed as a P13 per-run steal histogram.

**Failure/ownership limit:** afterExecution counters are synchronized completion observations, **not** a substitute for a full successful native join before freeing the backing record array. The unchanged pool retains P06/P07 native start/join failure questions; the research `@system`/fail-stop policy remains NO-GO for a general library API.

## Balanced configurations, reproducible order and expected output

[Research CSV driver](consumer/main.d) permutes all cases each round with a recorded seeded xorshift/Fisher–Yates schedule. **Every round contains all 1/2/4-worker configurations, for identical work and ingress settings**; it does not run all 1-worker cases first and all 4-worker cases last.

- **CI smoke:** kernel 0 and 128 iterations, ingress 64, workers 1/2/4, count 256, waves 2–3, one warm-up sweep and 2–3 measured sweeps depending on compiler profile. CI runs DMD 2.111.0 debug, LDC 1.41.0 debug, LDC debug + `-O3`, and LDC whole-package release. Both compilers additionally run a **tiny complete 45-configuration native-profile matrix** (64 tasks/wave, two waves, no warm-up and two sweeps), invoking the actual full-profile CSV validator before any real-XPS usage. These are correctness checks, not useful native performance data; no throughput threshold.
- **Native XPS:** five kernels (0/8/32/128/512), three ingresses (8/64/256), workers 1/2/4 — **45 configurations per sweep**. Each session has **2 warm-up + 7 measured sweeps**, count 2,048 per wave × 3 waves (6,144 executions per configuration). Default collector performs **three sessions with different seeds**, keeping session IDs separate.
- Each CSV row records `phase,round,order,seed,workers,count,waves,iterations,ingress,prepare_ns,pool_start_ns,waves_ns,join_ns,verify_ns,total_ns,retries,park_count,checksum`. The [parser](../../../../tools/research/m1_worker_scaling_analyze.py) verifies every configuration appears exactly once per sweep, complete order positions, valid nonnegative stages, stage partitions, and identical checksums across worker counts and ingress for the same kernel. A **4-worker / 2-worker ratio is computed within each measured sweep**, and spread is preserved; randomized cases are not adjacent matched-pair executions.
- **DO NOT** claim arbitrary work-stealing fairness, frequency stability, temperature causation, or CPU throughput based on the CI results.

## Executed initial qualification

[GitHub Actions #38415006955](https://github.com/alex-1974/concurrency-d/actions/runs/38415006955) **PASS** on DMD 2.111.0 and LDC 1.41.0, with the opt-in LDC debug `-O3` and whole DUB release configurations. P01–P12 and the workspace's DIP1000 language gates also remained passing.

**CI-only diagnostic:** in the three-sweep LDC release smoke, for 256 records/wave and three waves, ingress 64, 4w/2w within-sweep `waves_ns` median was **1.593** for the zero-iteration task and **1.379** for the 128-iteration task (three measurements per ratio). DMD debug and LDC debug/optimized samples show varying magnitudes. These are deliberately **NOT** performance acceptance data: the CI runner is shared, no physical-core topology/clock control is assured, and only two task sizes with three samples were checked.

The original code+CI source commit of the initial matrix was `bb4feed881698b95ab265a59b22f6460135950ee`. [Follow-up CI #38415953846](https://github.com/alex-1974/concurrency-d/actions/runs/38415953846) **PASS DMD and LDC** adds the complete 45-case native-profile preflight with small inputs, while retaining both compilers' existing research and negative tests. The within-sweep ratio label was also clarified to avoid implying adjacent paired timings.

## Native XPS execution

The opt-in [XPS collector](../../../../tools/research/m1_worker_scaling_xps.sh) does **not** run in CI. It uses available Linux CPU topology (`socket,core`) to choose **four logical CPUs drawn from four distinct physical cores** when possible and restricts the benchmark process tree to that mask with `taskset -c`. **This is a process affinity mask, not per-worker thread pinning**: Linux can still place or migrate multiple workers among the selected CPUs, and the actual per-thread core residency is not recorded. No assumption that CPU IDs 0–3 are distinct cores is made. `P13_CPUSET` can override the automatic topology selection, while `P13_SESSIONS` controls independent repetitions. CPU governor and `lscpu` metadata, source SHA/toolchains, seed, and before/after optional `sensors` snapshots are retained; **there is no continuous frequency or temperature sampling**, so thermal/frequency explanations are still only hypotheses.

From a **fresh detached worktree** of the already-existing research branch:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin research/m1-task-lifetime-boundaries
git worktree add --detach ../concurrency-d-p13 \
    origin/research/m1-task-lifetime-boundaries
cd ../concurrency-d-p13
bash tools/research/m1_worker_scaling_xps.sh \
    ldc2 /tmp/p13-xps-2026-10-13
```

The script refuses to overwrite an existing output directory or archive. It saves `manifest.txt`, original `raw/session*.log`, normalized `csv/session*.csv`, `summary.csv`, analysis diagnostics and `<destination>.tar.gz`. **Please review manifest/raw logs for local machine paths or host details before publishing.** The native archive has not yet been supplied; do not invent its results.

## Interpretation gates

- **If 4w/2w > 1 consistently at low iterations but approaches <1 for heavy kernels:** small-task admission/synchronization overhead is implicated, *not yet attributed to a specific lock, steal or park operation*.
- **If 4w/2w >1 even for 512 iterations under physical-core pinning across sessions:** investigate CPU frequency/turbo, affinity, cache topology, scheduler wakeups, contention, underused deques, and actual steal/idle counts. Still not automatically a correctness bug.
- **If ingress capacity changes the ratio materially:** target inbox contention/batch size/parking and per-producer retries, separately from owning-record storage.
- **If kernel/ingress results change by session or run position:** treat temporal drift and host noise as material and defer any performance decision.
- **If 4w/2w < 1 reproducibly only after pool reuse:** P12's total-time regression may have been dominated by per-batch startup/teardown, but that requires the *corresponding P12 phase data* to establish; do not assume.

**P13 decision now:** KEEP research test apparatus, DEFER scheduler changes. Preserve P12 native evidence unchanged and do not modify `source/`, the production build, `develop`, or R0.5 PR #35. The next candidate P14 (only after XPS evidence) would isolate steal/park/ingress event counts and correlate with verified scaling distributions or improve liveness fault protocols separately.


## Native scaling summary uploaded — 2026-10-13

The user supplied P13's **`summary.csv` only**, not its source archive/manifest or seven individual observations per configuration. We therefore qualified the **summary's completeness and internal consistency**, not the full physical-core, frequency, runtime or provenance controls.

See the [XPS summary review](evidence/xps-2026-10-13-summary-review.md), with uploaded source CSV SHA-256 `b5da24cb95adab3bcc06a23c741bb38ac9efcf5b0ec3d430d5de42ff4e3171dc`. All **135 expected rows** (3 named sessions × 5 kernel sizes × 3 inbox sizes × 3 worker counts) are present, each reporting seven measurements, three waves of 2,048 tasks and a checksum consistent across equivalent work.

The ratio of 4-worker/2-worker **configuration medians**, aggregated as the median of nine session×ingress comparisons for each kernel size, was **1.676× at 0 iterations**, **1.620× at 8**, **1.349× at 32**, **1.167× at 128**, and **0.899× at 512**. At 0–128 iterations **none of nine** session×ingress comparisons per kernel favored 4 workers; at 512 iterations **eight of nine** did. This is a workload-granularity crossover under reused M0 workers, *not* a measured cause or a general scheduler parameter recommendation.

Ingress 8 tended to be substantially slower than ingress 64 for very small tasks, accompanied by more reported `parkCount` and producer retry events. These are diagnostic associations, not instrumentation that identifies bottleneck cause. Within-row min–max spans remain broad; original per-sweep measurements and run order have **not** been supplied, so no true paired, order-adjusted ratio/confidence claim is made.

**Updated disposition:** KEEP P13 as a credible summary-level scaling signal; DEFER production tuning or public `@safe` claims. Prioritize a bounded P14 scheduler path/event instrumentation experiment plus the original P13 archive if possible.
