# R0.5 — Native XPS complete-victim-sweep A/B (2026-10-11)

**Status:** strong native experimental support for fixing the incomplete foreign-victim search; **research evidence only**, no production promotion.

**Raw input:** user-supplied `r05-xps-victim-sweep.tar.gz` (not committed, preserved unchanged); SHA-256 `46653953b304ff5567f8656a693acb30e4bc11ba993afa22358e7b43172cc111`.
**Measured Git SHA:** `882de033136617311e7b08ac20d84862a3b7a015`.
**Platform:** Dell XPS Intel Core i7-9750H (6C/12T), Linux 6.17.0-22-generic x86-64, LDC 1.41.0 / LLVM 19.1.7 release builds. The untraced A/B uses **identical batch8**, task/lifetime semantics, queues, notifications and record policies. Only victim candidate iteration count changes: N−1 slots (old) versus N slots (full), both skipping self.

## Evidence integrity and scope

All eight original archive files were parsed. Unique, complete factor matrix: **80 untraced burst cases**, **640 per-sibling starts**, **160 mixed throughput cases**, **120 paired comparisons**, **80 worker-search diagnostic cases**, **4,110 worker-local trace events**. Five rounds, four workers, 3/4 semaphore blockers, eight runnable siblings, nominal 100ms external release, gc/recycle, always/waiter; mixed: 6,000 typed/void/GC-visible tasks, 1/4 producers, retention budget 512, minimal/compute. All case IDs and gate-relative sibling classifications reconcile, accepted/claimed count is 11/12, all mixed cases complete 6,000 and no trace events are missing from case totals. Four-blocker tasks all started before the external release. Tracing is **not** used for performance numbers.

## Native uninstrumented burst results

Each row represents 20 independent cases and 160 individual runnable siblings, timing from **burst begin** rather than per-task submit.

| 4-worker scenario | Old scan (N−1 slots) | Full scan (N slots) |
|---|---:|---:|
| 3 blockers: siblings started before external gate | 102/160 | **160/160** |
| 3 blockers: started after final blocker, before gate | 28/160 | **79/160** |
| 3 blockers: started after gate | 58/160 | **0/160** |
| 4 blockers: started before gate | 80/160 | 83/160 |
| 4 blockers: started after final blocker, before gate | **0/160** | **0/160** |

For three blockers, full scan improves pre-gate sibling counts in **15/20 matched cases**, ties in five, never regresses. For four fully blocked workers neither policy guarantees progress.

Pooled nearest-rank **callable start offsets** across 160 tasks per line:

| Blockers | Scan | p50 | p95 | p99 |
|---|---|---:|---:|---:|
| 3 | Old | 65.0µs | **100.514ms** | **100.572ms** |
| 3 | Full | 60.6µs | **155.5µs** | **173.3µs** |
| 4 | Old | 244.8µs | 100.343ms | 100.650ms |
| 4 | Full | 115.6µs | 100.348ms | 100.695ms |

The tail values reflect an artificial 100ms semaphore gate and are **not** general task-latency SLOs. The per-case p99 for just eight siblings equals its maximum.

## Paired mixed throughput: full/old ratio

Median of matched per-round throughput ratios, **not** ratio of unrelated medians. Each cross-policy row aggregates 20 pairs (2 storage × 2 notify × 5 rounds):

| Workload | 1 producer | 4 producers |
|---|---:|---:|
| Minimal | **1.087×** (12/20 faster) | **0.983×** (8/20 faster) |
| Compute | **0.985×** (10/20 faster) | **1.046×** (17/20 faster) |

At current defaults **gc/always**, median of five pairs: minimal / 1 producer **1.280×** (3/5), minimal / 4 **1.029×** (3/5), compute / 1 **0.954×** (2/5), compute / 4 **1.046×** (4/5). Ratios vary substantially; 6,000-task child processes run for just tens of milliseconds and do not control affinity, governor or warmup. Whole-child CPU and context-switch samples include startup/GC/shutdown; they are **not** a worker-idle CPU or energy metric. No reliable universal throughput advantage—or absence of cost—has yet been demonstrated.

## Worker-local mechanism evidence and caveats

Separate worker-local diagnostic, three blockers, 20 traced cases per variant:

| Spare-worker events after final blocker / before gate | Old | Full |
|---|---:|---:|
| Siblings started before gate | 96/160 | **160/160** |
| Successful steals | 18 | **89** |
| Unsuccessful steal attempts | 62 | **219** |
| Actual spare-worker waits spanning gate | 20 | 20 |

Old spare workers wait **while siblings remain delayed**. With full scan they wait **after all eight siblings have started**; a wait itself is not a defect. Complete scanning does more work (~3.5× failures in the measured window) but finds more tasks. Trace changes scheduling: 14/20 three-blocker old-scan on/off cases have different pre-gate sibling counts, whereas full scan is 160 in both. No globally serialized cross-worker event ordering is inferred.

**Concrete source mechanism:** `foreach (_; 0 .. _queues.length-1)` consumes N−1 candidate *indices* and skips `self`. With N=4, self=2 and nextVictim=1 it attempts 1, skips 2, attempts 3, and **never attempts 0** before possibly parking. The full-scan research variant visits N candidate indices, yielding N−1 actual foreign victim attempts. This explains a concrete missed search opportunity, corroborated by XPS, but is not a theorem that no task can ever be delayed after the change.

**Independent fairness issue to qualify:** After a complete *unsuccessful* N-position scan, `nextVictim` returns to the **same** initial victim (modulo N). The old N−1-position scan rotates the next starting victim. Thus complete coverage and scan-start rotation must be examined independently before accepting the code as a production fairness policy. More failed steals, idle CPU, worker count scaling and sustained compute load remain unresolved.

## Engineering decision

**ACCEPT:** Native 3-blocker improvement is reproducible with batch8 and supports an isolated correction to incomplete victim coverage; worker-local events support the mechanism. DMD 2.111 x86, LDC 1.41 x86/ARM64 consumer and research CI for the measured SHA are green.

**KEEP:** Production `IngressBatchSize=8`, `freshGc`, `NotificationPolicy.always`, old scheduler logic; Draft PR #35 remains unmerged, Issue #20 open, `develop` unchanged.

**NEXT:** Run larger and longer mixed minimal/compute cases, 1/4/8-worker and spare-worker idle controls, fair scan-start rotation, energy/CPU-resource and contextual switch diagnostics. Preserve exact paired baselines, verify portable DMD/LDC safety and task accounting. Separate a small production victim-coverage fix from this research PR only after acceptance evidence. No general progress guarantee when all workers block. No changes outside `concurrency-d`.
