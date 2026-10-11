# R0.5 native XPS — Batch 1/2/4/8 and worker-search mechanism (2026-10-11)

**Status:** reproducible native research evidence; hypothesis discovered and
isolated for A/B. No production default promotion, no release decision.

**Measured commit:** `092bb139ebf6ef717717a7125fca895bcf568419`.
**Raw input:** user-provided `r05-xps-intermediate-batch-and-search.tar.gz`,
retained separately. Exact provenance in the three original
`environment.txt` files: Linux x86-64, LDC 1.41.0 / LLVM 19.1.7,
Dell XPS, five paired rounds, 4 workers, nominal 100ms gate, 8 siblings.

All 19 evidence files were read. Two independent untraced batch sweeps
each contain 160 burst cases, 1,280 sibling starts, 160 mixed cases,
240 paired comparisons; the worker-search experiment has 80 cases,
320 worker summaries and 3,497 bounded local events. Combined: **320
untraced burst cases, 320 mixed cases, 2,560 sibling starts and 80
paired worker-search cases**. All expected keys are unique and present,
count conservation and actual gate-relative start classifications match,
and all mixed cases report 6,000 completed tasks.

The `minimal`/`compute` distinction changes **only mixed throughput
task-body work**; the burst probe is the same in both sweeps. Therefore
the two burst datasets are repeated independent observations, not
different CPU-compute burst workloads.

## Gate-relative sibling progress (20 cases × 8 siblings per row)

| Branch of sweep | Blockers | batch1 | batch2 | batch4 | batch8 baseline |
|---|---:|---:|---:|---:|---:|
| minimal | 3 | 160/160 | **160/160** | 156/160 | 85/160 |
| minimal | 4 | 0/160 | **151/160** | **153/160** | 81/160 |
| compute-series repeated burst | 3 | 160/160 | **160/160** | 156/160 | 89/160 |
| compute-series repeated burst | 4 | 0/160 | **159/160** | **157/160** | 90/160 |

All four blockers began before external release in **all 80
four-blocker burst cases in each dataset**. Across **all** batch
sizes, zero siblings started between the final blocker start and gate
release with four blockers. Pre-gate progress in batch2/4/8 occurs
**before saturation**; this is ordering, not a proof of progress when
all workers are blocked.

With **three** blockers, siblings started *after all blockers*
but before gate, from 160 siblings for each batch:

| Sweep | batch1 | batch2 | batch4 | batch8 |
|---|---:|---:|---:|---:|
| minimal | **160** | 7 | 42 | 19 |
| repeated burst | **160** | 10 | 25 | 19 |

Batch2 thus often achieves early sibling starts by running them before
the final blocker, **not** by reliably stealing queued work after three
workers have blocked. These are not equivalent fairness guarantees.

### Pooled sibling start offsets from burst start

These are **not** submit-to-start times or contractual latency SLOs.
Nearest-rank p95/p99 over 160 siblings per batch and blocker count:

| Sweep / blockers | batch | p50 (µs) | p95 (µs) | p99 (µs) |
|---|---:|---:|---:|---:|
| minimal / 3 | 1 | 112.3 | 191.0 | 192.9 |
| minimal / 3 | 2 | 90.4 | 154.1 | 169.3 |
| minimal / 3 | 4 | 60.3 | 105.4 | **100,642.7** |
| minimal / 3 | 8 | 148.5 | **100,680.7** | **100,720.0** |
| minimal / 4 | 1 | **100,383.4** | 100,705.1 | 100,795.4 |
| minimal / 4 | 2 | 88.4 | **100,198.8** | 100,202.3 |
| minimal / 4 | 4 | 75.4 | 149.5 | **100,392.3** |
| minimal / 4 | 8 | 110.5 | **100,685.0** | 100,743.6 |

The p99 of 160 samples is still sample-dependent, and a p99 of
eight siblings **within one case** is just its observed maximum.
One batch2/minimal four-blocker case had **8/8 siblings** delayed,
explaining that group's p95 at approximately 100ms despite 151/160
pre-gate progress. In the repeated burst dataset, only one sibling
was delayed at batch2/four-blocker, yielding pooled p95 ≈183µs.

## Mixed throughput (6,000 tasks per child, five matched rounds)

The following are medians of **within-round batch/batch8 throughput
ratios**, not independent median-throughput ratios.

| Workload / producers | batch1 | batch2 | batch4 |
|---|---:|---:|---:|
| minimal / 1, all storage/notify, 20 pairs | **1.076×** (15/20 faster) | 0.992× (10/20) | 0.980× (8/20) |
| minimal / 4, all controls, 20 pairs | **1.060×** (16/20) | 0.992× (9/20) | 1.008× (12/20) |
| compute / 1, all controls, 20 pairs | 1.002× (10/20) | 1.010× (11/20) | 0.987× (8/20) |
| compute / 4, all controls, 20 pairs | 0.985× (9/20) | **0.931×** (7/20) | **0.950×** (8/20) |

For the actual default `freshGc/always`, four producers:
- minimal: batch1 **1.035×**, batch2 **0.952×**,
  batch4 **1.026×**;
- compute: batch1 **0.974×**, batch2 **0.924×**,
  batch4 **0.881×**.

Case elapsed times are roughly 14–30ms, so startup, order, platform
frequency and sample noise matter. The compute variant invokes
the repo's deterministic CPU rounds but is still a short microbenchmark.
No evidence justifies claiming batch2/4 improves general throughput.
CPU resource samples are whole-child diagnostics, **not idle-worker CPU**.

## Worker-local search trace: concrete mechanism

The separate worker-search experiment uses baseline batch8 versus batch1,
with and without opt-in worker-local `R05WorkerSearchTrace`. These
instrumented results must **not** be counted as uninstrumented latency.

At three blockers and batch8 across 20 traced cases:
- **84/160 siblings** start before release, 76 are delayed;
- in **20/20 cases**, all blockers have started, there is exactly one
  spare worker and that spare worker enters a real `Condition.wait`
  that spans the external gate release;
- all 20 cases have some siblings delayed;
- during the post-final-blocker/pre-gate window the spare workers emit
  **52 stealMiss** and **17 stealHit** events across the cases;
- 17 of the spare-worker park checks are in that window; in the
  other three cases the eventual gate-spanning wait began earlier.

For batch1/three blockers, the spare worker also waits until the gate,
but **only after all 160 siblings have already started**. Waiting by
itself is therefore not a defect; the defect hypothesis concerns
waiting **with stranded runnable work**. The diagnostic changes
scheduling: batch8 pre-gate sibling counts differ in **8/20 paired
untraced/traced cases**, so do not treat timestamps as a causal oracle.

### Source-visible victim-scan omission

In `source/concurrency/internal/submission_pool.d` at measured HEAD:

```d
foreach (_; 0 .. _queues.length - 1)
{
    const victim = nextVictim;
    nextVictim = (nextVictim + 1) % _queues.length;
    if (victim == self)
        continue;
    // attempt steal(victim)
}
```

The code examines **N−1 candidate indices** but does not guarantee
**N−1 *foreign* victim attempts**, because `self` may be one of
those candidates. After successful stealing from worker 0, a worker
with `self=2` can have `nextVictim=1`; the next three iterations
sample victims **1, 2 (skipped self), 3**, omitting worker 0 even if
worker 0 still has queued work. Real native worker-local sequences
show that pattern, followed by a real wait until the gate and owner
pops of remaining queued tasks after gate release. This explains a
specific *missed search opportunity* and is an actionable scheduler
coverage deficiency; the evidence does **not** yet assign all
stranded tasks exclusively to this deficiency.

## Decision and next isolated experiment

The incomplete victim scan must be isolated **before choosing a
preferred ingress batch size**. Research-only
`version (R05FullVictimSweep)` changes the candidate count from
`N−1` to `N` while still skipping `self`, ensuring every
foreign victim receives one attempt per full unsuccessful search.
No queue implementation, memory ownership, public API, notification
policy or default batch size changes. Separate untraced burst and
mixed throughput configurations and a separately traced search
variant compare with the identical batch8 baseline. CI/DMD/LDC
must pass before native XPS evaluation.

**KEEP** `IngressBatchSize=8`, `freshGc`, `always` as defaults,
PR #35 Draft, Issue #20 open and `develop` untouched.
**DEFER** public/default adoption of complete scan, batch2/4,
new parking policy or any `containers-d` changes pending isolated
performance, semantic parity and cross-platform evidence. General
progress is **not guaranteed** when all workers block.
