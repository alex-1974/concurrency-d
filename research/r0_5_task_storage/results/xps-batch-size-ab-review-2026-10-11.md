# R0.5 native Dell XPS ingress batch-size A/B — 2026-10-11

**Status:** qualified *research observation*, NOT a production promotion.
**Experiment HEAD:** `931ede93ffc574c0450508724238ef1d03de0b67`
**Source evidence:** user-supplied `r05-xps-batch-size-ab.tar.gz` (seven original CSV/environment files), retained externally. This document contains independently recomputed aggregates, not the raw observations.

## Provenance and preflight

Dell XPS / Intel i7-9750H (6 cores, 12 threads), Linux 6.17.0-22-generic x86-64, LDC 1.41.0 (LLVM 19.1.7). All benchmarks use release builds with the ordinary `R05TaskTrace` instrumentation **off**. A compile-time-only `R05IngressBatchOne` variant is compared against the unmodified batch8 build.

Five rounds, 4 workers, blocker gate nominal 100ms, 8 runnable sibling tasks, all combinations of 3/4 blockers, `freshGc/recycleTyped` and `always/waiterAware`. Separate mixed tests use 6,000 tasks, 1/4 producers, retention budget 512, `minimal` work with mixed typed/void and GC-reachable captures.

80 burst cases, 80 mixed throughput cases, 640 individual sibling starts; every expected case/round key is present without duplication. All bursts conserve accepted/claimed counts and all sibling starts match the gate-relative classification. Every process exited successfully, with benchmark checks for exact-once execution, typed results and clean join. Mixed cases report 6,000 completed tasks each. The git SHA in `environment.txt` matches the experiment HEAD.

The actual `gateRelease` timestamp, not the nominal 100ms sleep, is used throughout. In **one** batch8 / 4-blocker / recycle-waiter case, the last blocker started ~43µs *after* gate release. Do not conflate pre-gate sibling progress with progress after all blockers have begun waiting.

## Native XPS burst evidence (pooled across the 4 policy combinations)

| Blockers / 4 workers | Batch | Siblings before gate | After final blocker begins but before gate | Start p50 | Start p95 | Start p99 |
|---|---:|---:|---:|---:|---:|---:|
| 3 | 8 | 99/160 | 32/160 | 78.6µs | 100.23ms | 100.35ms |
| 3 | 1 | **160/160** | **160/160** | 105.8µs | **194.6µs** | **198.7µs** |
| 4 | 8 | 96/160 | **0/160** | 137.4µs | 100.31ms | 100.68ms |
| 4 | 1 | 0/160 | **0/160** | 100.19ms | 100.32ms | 100.45ms |

These are nearest-rank distributions over **160 sibling start offsets from burst begin** per row, not submit-to-start measurements. They are conditional on this eight-sibling, externally blocked test. A per-case p99 of eight tasks would be only the maximum and must not become a contractual p99 gate.

With 3 blockers the spare worker can process all 8 pending siblings using batch1; with batch8 some siblings were already claimed into blocked owners' deques. Across all 20 combinations/rounds, batch1 starts 160/160 before release while batch8 starts 99/160. The median can be slightly slower even when the high tail shrinks dramatically.

With 4 blockers batch1 prioritizes all 4 blocking tasks, leaving no free worker to run the 8 siblings before release. Batch8 starts 96/160 before release, but **none** after the final blocker begins; all early starts precede full worker saturation. Neither batching policy guarantees runnable progress when all workers block. This is a work-ordering/availability tradeoff, not a correctness failure.

## Mixed throughput: paired batch1/batch8 ratio

The medians below are of **five within-round ratios**, not ratios of separately summarized throughputs. Values above 1 favor batch1.

| Storage | Notification | 1 producer | 4 producers |
|---|---|---:|---:|
| gc | always | 1.032x (3/5 faster) | **0.991x (2/5 faster)** |
| gc | waiter | 1.090x (3/5) | 1.025x (4/5) |
| recycle | always | 1.017x (3/5) | 1.061x (5/5) |
| recycle | waiter | 1.328x (5/5) | 1.105x (5/5) |

Across all 20 pairs for each producer count, median batch1/batch8 ratio was 1.091x (14/20 pairs faster, range 0.850–1.814x) for one producer, and 1.063x (16/20, range 0.893–1.300x) for four producers. Under **current defaults** `gc/always`, the four-producer median ratio is **0.991x**, so **no stable throughput improvement is demonstrated for the production-default configuration**.

Mixed throughput measures internally timed complete admission/execution/shutdown; it does not include the artificial burst sleep. CPU/context-switch fields are whole-child resource diagnostics, **not** worker idle-CPU measurements. The minimal 6,000-task cases run ~20–35ms, too briefly to dismiss frequency, startup, process order and other noise. No controlled warmup, affinity or frequency calibration was documented.

## Mechanism, scope and engineering decision

The **only scheduler variant** in this A/B is `IngressBatchSize=1` versus established `8`; memory lifetime, queue algorithms in `containers-d`, typed result semantics and notification policies are unchanged. This is direct evidence that batch claim size influences placement/head-of-line delay in this narrow workload. It is NOT an endorsement of universal batch1.

**KEEP** batch8, `freshGc` and `always` as library defaults. Leave Draft PR #35 unmerged, Issue #20 open, `develop` unchanged. The three-blocker tail result is accepted as repeatable *research evidence*, but batch1 default promotion is **DEFERRED**.

**NEXT:** use isolated batch2/batch4 or an explicitly fair claim-budget hypothesis *only if* paired A/B shows a favorable balance under both blocker counts; independently investigate the remaining free worker's unsuccessful steals and park/wake decisions. Qualify longer CPU-bound and memory-intensive mixed workloads with controlled warmup/affinity, actual per-task release-LDC latency distributions, resource efficiency and safety gates on DMD/LDC x86-64/ARM64. **No queue replacement, help-while-wait or `containers-d` changes justified yet.**

Reproduction: `python3 tools/research/r05_batch_size_ab.py --compiler=ldc2 --rounds=5 --burst-ms=100 --blockers 3 4 --policies gc recycle --notify always waiter --tasks=6000 --producers 1 4 --budget=512 --workload=minimal --output=evidence/r05-xps-batch-size-ab`. The seven raw evidence files remain unchanged in the source archive.
