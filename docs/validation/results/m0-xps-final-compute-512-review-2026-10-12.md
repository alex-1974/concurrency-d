# M0 Dell XPS — final sustained compute A/B at ingress budget 512

**Date:** 2026-10-12. **Disposition:** **accept this specific performance qualification as sufficient to advance the narrowly scoped full-victim-coverage candidate to final maintainer review**, but do not infer universal zero overhead or merge PR #37 without the required explicit review/approval. Research PR #35 stays independent.

## Original evidence and exact revisions

- Original XPS archive: `m0-xps-final-compute-512.tar.gz`.
- SHA-256: `228e5a00e23b64b7a2c1adec99e0315fdd45c010eb3216c5aea417c2efc12dce`.
- Measured validation harness Git SHA: `41c876164863f90f6a7e19c47a165e8cd47f040d`.
- Baseline M0 `develop`: `822a866d866dbb176f5435a41b09d189b8d0c4cb`.
- Production candidate, Draft PR #37: `31f97b8315980b4b52a97cb1706a507a1422eaa5`.
- Identical injected benchmark source SHA-256 `e031888b299b2b3590a7ec05c42b38aeb58cee1bf8c0f83fab84cbba5b8eb9b8`. Both detached worktrees used the same release compiler, DUB dependency resolution, task semantics, bounded FIFO inbox and borrowed-TaskRef M0 pool. No changes to the queue primitive or task ownership.
- Dell XPS Intel i7-9750H (6C/12T), LDC 1.41.0 / LLVM 19.1.7, Linux 6.17.0-22-generic, DUB 1.40.0, `powersave` governor. `scaling_cur_freq` samples are instantaneous across CPUs, **not** workload-averaged clocks. No CPU affinity, clock, thermals or external load controlled by the runner.

**Parameters:** `--mixed-only --cpu-snapshots --rounds=20 --tasks=300000 --workers 1 4 8 --producers 4 --workloads compute --compute-rounds=1024 --budget=512 --cooldown-ms=100`. The baseline/fix execution order alternates evenly (10 first runs each per worker count).

Archive has all five expected raw files: `mixed.csv`, `pairs.csv`, `control_pairs.csv`, `summary.csv`, `environment.txt`. Exactly **120 mixed process runs**, **60 same-round comparisons** and **36,000,000 total completed tasks**; every run accepted and completed 300,000 tasks, with identical deterministic checksums `15853781091740884488`, no duplicate condition keys or missing fields. All 360 resource/elapsed/throughput metric pair entries, 40 one-worker-normalized diagnostic pairs and 18 grouped summary rows are present and reconcile. Task result verification in the consumer is outside the measured internal elapsed interval. Child resource accounting is a separate whole-process diagnostic.

## Core result: paired 300k-task throughput

**Throughput ratio is fix/baseline**, calculated per matching round as baseline internal elapsed divided by fix internal elapsed. The displayed per-side throughputs are *independent medians*; the third column is **median of 20 paired ratios**, which need not equal the ratio of per-side medians. All tasks are real typed-independent borrowed records with deterministic 1,024-iteration work, validated exactly once.

| Workers | Baseline median tasks/s | Fix median tasks/s | Median paired fix/baseline | Fix wins / 20 | Paired IQR |
|---:|---:|---:|---:|---:|---:|
| **1** | **269,692** | **265,169** | **0.9570×** | **8** | 0.895–1.136× |
| **4** | **904,967** | **911,444** | **1.0226×** | **13** | 0.975–1.139× |
| **8** | **1,379,218** | **1,368,947** | **0.9951×** | **10** | 0.960–1.019× |

For the **target 4-worker/4-producer compute case**, the fix is **~2.3% faster in the median within-round comparison**; the earlier 100k-task 4-worker/4-producer result of **0.979×** does not replicate as a persistent slowdown under this larger workload. Individual ratios range 0.896–1.418×; 7/20 pairs still favor the baseline. For eight workers the ratio centers close to unity with 10/20 wins. The no-foreign-stealing one-worker control fluctuates markedly from **0.641× to 1.632×**, showing strong non-scheduler/environment variability; its median of 0.957× **does not establish a constant 4.3% overhead**.

For descriptive uncertainty only, a basic iid within-round resampling bootstrap (50,000 draws, sample n=20, no time-series/drift model) yields median ratio percentile intervals:
- one worker: **0.902–1.094×**
- four workers: **0.986–1.110×**
- eight workers: **0.967–1.016×**.

These *illustrate uncertainty* and are **not** a certified equivalence/noninferiority test or unconditional statistical performance guarantee. Sign counts are also insufficient to claim a universal speedup (e.g. four-worker 13/20).

## Fairness/resource considerations

- **One-worker drift control:** median same-round `(4-worker fix/base) / (1-worker fix/base)` **1.062×** (12/20 above one); eight-worker corresponding median **1.002×** (10/20 above one). These controls **cannot remove** the absolute consumer-visible ratio and have wide variation.
- **Worker scaling:** same-round median throughput at 4 versus 1 workers is **3.03× baseline vs 3.29× fix**. At 8 versus 1, **4.72× baseline vs 5.06× fix**. The results do **not** reproduce the negative scaling seen in the separate R0.5 OwnedTask synthetic-pipeline research; different implementations and measurements must not be conflated.
- **4-worker CPU/resources:** median baseline/fix user CPU `2,218,002 / 2,156,053 µs`; process sys CPU `849,098 / 860,553 µs`; producer full-ingress retries `439,997 / 394,256`; voluntary context switches `33,353 / 32,979`. The matched deltas are noisy, but there is **no sustained resource explosion** associated with the fix in this dataset.
- CPU clock snapshots before the 4-worker child have independent medians **3.50 GHz baseline vs 3.83 GHz fix**. This **could** contribute to an apparent speed advantage, but the readings are snapshots, not mean frequencies or deterministic clock control. Some snapshots dip to 0.8 GHz in both modes. Do not claim a 2.3% intrinsic scheduler speedup.
- `process_peak_rss_kib` is from cumulative `RUSAGE_CHILDREN.ru_maxrss`, **not** per-case peak RSS; do not compare it as memory overhead.
- **No idle/wake measurements were made in this new archive**. The prior larger 20-round native idle/wake follow-up did **not** reproduce the original suspected four-worker p95 regression, but did not establish tail equality or a p99 SLA.

## Engineering recommendation / promotion boundary

**Mechanism and correctness:** the original N−1 candidate search could skip self and miss a foreign owner deque before parking; N candidate positions cover each foreign worker once without rotation. PR #37 restricts the code change to this loop bound and a self-contained regression test expansion; DMD 2.111 x86 and LDC 1.41 x86/native ARM64 consumer gates PASS on the exact candidate SHA. Three-blocker native R0.5 work provides independent head-of-line mechanism evidence; full worker saturation still has no progress guarantee.

**Performance disposition:** the dedicated sustained 4-producer/4-worker compute gate no longer shows the suspected steady slowdown; 8-worker results are approximately neutral. An isolated 1-worker overhead and small adverse cases remain **unresolved within current measurement noise**, not proved absent. Given a demonstrated starvation-prone coverage defect, this is sufficient evidence to recommend **advancing PR #37 to final maintainer review and explicit performance-tradeoff acceptance**. No further broad tuning/alternate victim rotation is justified merely to chase noisy small median shifts.

**State:** **no automatic merge or release**. The workspace requires review of the exact PR head and green checks and explicit promotion from Draft. Preserve grandfathered PR #35 and Issue #20 evidence; retain this validation branch/raw archive, do not overwrite/delete any untracked native research assets. `develop`, `main` and other workspace repositories remain untouched until an approved squash merge of PR #37.

Related records: [original 100k M0 comparison](m0-xps-victim-coverage-review-2026-10-11.md), [native wake follow-up](m0-xps-victim-wake-followup-review-2026-10-12.md), [validation protocol](../m0-full-victim-coverage-final-compute-gate.md).
