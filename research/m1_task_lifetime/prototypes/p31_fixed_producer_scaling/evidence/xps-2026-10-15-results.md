# P31 — Native XPS fixed-producer-scaling evidence (2026-10-15)

**Status:** Research evidence; diagnostic only. **Decision:** retain P29 lifetime guarantees; investigate M0 producer/worker contention in a separate P32 mechanism study. No production promotion.

## Provenance

- Submitted archive: `concurrency-p31-xps-20261015T185755Z.tar.gz`
- SHA-256 of the uploaded archive: `f5d60e71775fe7a2af88fff345dbc0d333786b3c61f2caa490ade3385bc9900a`
- Git HEAD recorded in archive: `500a58c7cc06928bb2d46736b3f338ed219a758a`
- Original production blob pins: `owned_task.d=e74d6a73f956c562eab176e27687a47249f5815d`; `submission_pool.d=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- Host: xps-15, Intel Core i7-9750H (six physical cores, 12 logical CPUs), Linux 6.17.0-22-generic, governor `powersave`.
- LDC 1.41.0 (DMD frontend 2.111.0, LLVM 19.1.7), DUB 1.40.0; DUB whole release, `-O3`.
- Recorded UTC capture: 2026-10-15 18:57:55 through 18:58:07.
- CPU0 start/end sampled frequency: 4,099,784 / 3,999,991 kHz. These are not continuous thermal or frequency measurements.
- The original worktree had numerous **untracked** local benchmark outputs and a generated P23 module. There is no reported modification of tracked files. This is a provenance limitation, not evidence that those unrelated untracked artifacts affected P31.
- Source is the uploaded immutable archive; do not commit its raw CSV or claim this Markdown reproduces raw per-round measurements.

## Protocol and completeness

- Fixed per arm: 8,192 accepted tasks, four workers, ingress 128, retention 1,024.
- Producer counts: 1 / 2 / 4; ownership modes: `m0`, `deferred` (P23), `managed` (P29); task kinds: `shared_atomic`, `sharded_atomic`, `minimal`.
- Three warm-up and nine measured rounds, each covering 27 combinations: **324 unique CSV records** (81 warm-up + 243 measured).
- All records satisfy `accepted == completed == count == 8192`, expected constant dimensions and `attempts == 8192`.
- Each atomic arm has `executed == 8192`, `checksum == 491520`. Minimal arms have `executed == checksum == 0` because task-local atomics are intentionally omitted; actual completions are verified by the native M0 executor.
- Archive entries were inspected as ordinary files with no symlinks or traversal, and the included `analysis.txt` states `P31_FIXED_WORK_VALIDATED rounds=9`. The independent CSV inspection confirmed record counts and dimensions; the report does not represent a fresh local build.

## Submission phase, median of nine measured rounds (milliseconds)

This interval **includes producer start/join and overlapping worker execution**, so it is not isolated enqueue latency. Values below are the medians of absolute submit times, and are not to be divided to infer paired scaling.

| Task kind | Owner | 1 producer | 2 producers | 4 producers |
|---|---|---:|---:|---:|
| shared_atomic | m0 | 16.639 | 34.009 | 37.052 |
| shared_atomic | deferred | 17.571 | 32.179 | 37.448 |
| shared_atomic | managed | 19.331 | 31.909 | 38.747 |
| sharded_atomic | m0 | 16.797 | 33.105 | 37.399 |
| sharded_atomic | deferred | 16.727 | 31.869 | 37.652 |
| sharded_atomic | managed | 17.944 | 33.417 | 39.178 |
| minimal | m0 | 16.415 | 28.916 | 36.070 |
| minimal | deferred | 17.017 | 30.380 | 37.200 |
| minimal | managed | 18.437 | 32.763 | 37.781 |

Raw observed submit-time ranges by profile are retained in the uploaded `summary.json` and `benchmark.csv`; e.g. shared_atomic/m0/1 producer 15.563–27.365 ms; shared_atomic/m0/4 producers 30.584–38.967 ms. These are nine-run ranges, **not confidence intervals**.

## Within-round paired throughput scaling

Because task count stays 8,192, the paired throughput ratio `throughput(N producers)/throughput(1 producer)` is equivalently `submit_ns(1)/submit_ns(N)` for the same measured round, work kind and owner. Each value below is the **median of nine paired ratios**, not the ratio of the two absolute medians.

| Task kind | Owner | 2p/1p | 4p/1p |
|---|---|---:|---:|
| shared_atomic | m0 | 0.556 | 0.501 |
| shared_atomic | deferred | 0.548 | 0.454 |
| shared_atomic | managed | 0.601 | 0.542 |
| sharded_atomic | m0 | 0.506 | 0.442 |
| sharded_atomic | deferred | 0.589 | 0.516 |
| sharded_atomic | managed | 0.544 | 0.452 |
| minimal | m0 | 0.613 | 0.463 |
| minimal | deferred | 0.579 | 0.437 |
| minimal | managed | 0.609 | 0.475 |

Across all 18 paired categories above, 17 show slower submissions for N producers in **all nine rounds**; only minimal/m0/2p has eight slower rounds and one slightly faster. The directional conclusion of a substantial multi-producer slowdown is robust *within this run*.

For `managed / deferred`, paired median submit-time ratios (larger = slower manager arm) are: shared_atomic 1.139 / 1.052 / 1.020, sharded_atomic 1.077 / 1.045 / 1.058, minimal 1.090 / 0.993 / 1.047 for 1p / 2p / 4p. These differences are noisy, and the run does **not** isolate P29 lock cost.

## Interpretation and decision

**Supported:** with total tasks, workers and budgets held fixed, increasing producer count from one to two or four worsened submission-phase throughput for every owner/work combination. P30's changing-count/worker confounding is therefore not sufficient to explain this separate P31 result. The slowdown also occurs for `minimal` tasks without task-side shared counter updates. Sharding the task-side counters did not reliably remove it.

**Not supported:** identifying a particular mutex, cache-coherence line, atomic instruction, GC pause, worker-parking step, thread scheduling policy or producer-side algorithm as causal. Each task kind changes the callable and its state; cross-kind differences are mechanism diagnostics, **not** matched end-to-end scheduler benchmarks. Producer-side reported allocations are around 3.24 MB per arm (~396 bytes per accepted task) and are **not** total heap allocations, RSS or a per-task cost proof. CPU governor and environmental drift remain possible confounders. No C++ parity claim.

**KEEP:** P29 generational handles, native join certainty, GC-root retention and fail-stop on uncertain native lifecycle. **NO-GO:** optimizing or promoting production on the basis of this single diagnostic capture. **P32 next:** bounded paired instrumental/non-instrumental study of the actual M0 producer admission path and worker resource/parking mechanisms, with fixed task/worker budgets and semantically matched control; measure mechanism counters separately from uninstrumented throughput, avoiding changes to `source/` or safety guarantees.

Related: [P31 protocol](../README.md), [P30 evidence](../../p30_ownership_benchmark/README.md).