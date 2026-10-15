# M1 P30 — Original M0 versus P23 and P29: matched native performance

**Date:** 2026-10-15. **Status:** reproducible research benchmark
with **no XPS timing evidence yet**. CI establishes source provenance,
compilation, equal accepted-task work and paired sample structure;
**CI throughput is diagnostic only**. Do **not** promote an ownership
API on shared-runner timing.

**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[PR #38 Draft](https://github.com/alex-1974/concurrency-d/pull/38).

**Prior constraints:** [P23 real owner deferred startup](../p23_real_owned_lifecycle/README.md),
[P25 paired ownership](../p25_owner_modes/README.md),
[P27 native process-exit finding](../p27_registry_transitions/README.md),
[P29 generation-tagged manager](../p29_generational_owner/README.md).

## Question

What **incremental execution cost** does the real P29 generational
owner manager impose, versus a direct executor call with the **same
real M0 worker pool, TaskRef record implementation, bounded retention,
task callable and producer workload**?

What part of total lifecycle cost belongs to executor construction/
native startup, what part to contention on admission, and what part to
native join and root-release? Is the additional P29 manager lock on
every submission large enough to justify testing a different
production-owned entry path?

The benchmark does **not** claim that the original executor's
lifetime contract is equivalent to the P29 process-rooted owner.
That original is an **unmanaged reference control** and retains the
original P20 unknown-native-shutdown limitation; P29 imposes stronger
independent-root obligations. No raw "managed is slower/faster" ratio
justifies weakening those obligations.

## Exact implementations, no simulation of the manager

The benchmark is conditionally compiled with
`--d-version=P30Benchmark` **inside the existing
[P29 consumer](../p11_real_pool/consumer/p29_generational_owner.d)**.
Its `GenerationalManager.publish(F)(h, work)` uses exactly the P29
Mutex → generation+phase check → in-flight claim → original M0
`trySubmit` → claim release algorithm. P30 only generalizes the
concrete work type from P29's `Job` to `F` so the same code can
execute the common benchmark `PerfJob`. Original P29 tests remain
in their unchanged default entry point.

Three performance arms:

| CSV mode | Executor / native task implementation | Admission and lifetime |
|---|---|---|
| `m0` | **Original** `concurrency.internal.owned_task.OwnedTaskExecutor`, real M0 pool | Direct `trySubmit`, constructor starts workers, direct native join; P20 contract limits apply. |
| `deferred` | **P23 source-pinned** research copy of the same `OwnedTaskExecutor` and unchanged M0 pool | Explicit `researchStart`, direct `trySubmit` and join, controller holds reference until join. No independent registry. |
| `managed` | **The same P23 source-pinned copy** and unchanged M0 pool | Actual P29 `GenerationalManager.enroll/start/publish/orphan/joinOrphan/reclaim`, generation checks, in-flight caller operations and explicit `GC.addRoot/removeRoot`. |

Exact original blob pins (verified before every run):

- `source/concurrency/internal/owned_task.d`:
  `e74d6a73f956c562eab176e27687a47249f5815d`;
- `source/concurrency/internal/submission_pool.d`:
  `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

The [P23 generator](../../../../tools/research/m1_p23_make_owned.py)
creates a temporary research copy which is removed after the run.
No original production source, native scheduler, work-stealing
code, public DUB package or unrelated repository is modified.

## Equal-work correctness oracle and timing phases

Each arm creates an equivalent executor with the same
`workers`, `ingress` and `retained` capacities. A parameterized
number of native producer threads submit exactly `count` copies of
the **same typed `PerfJob`**. It adds the fixed value `60` to
an atomically updated checksum and increments an independently
atomically recorded execution count. Every accepted record has
the same `OwnedNode`, `TaskRef`, result-cell and dropped
handle behavior across the arms.

The producer repeats the real `trySubmit` path under the same
bounded ingress/retention pressure until each required task is
accepted (with timeout and backpressure attempts counted). The
manager's algorithm must not bypass the original M0 queue.
Before emitting a sample, the benchmark requires, **in all modes**:

```text
accepted == completed == producer_acknowledged == executed == count
checksum == count * 60
attempts >= count
root ledger paired (managed)
native join completed (all arms)
```

These are always-evaluated `check()` oracles; none disappear under
whole `-release`.

Timing measurements use `MonoTime.currTime`:

- `create_start_ns`: original M0 constructor+worker start, P23
  explicit constructor+start, or P29 manager creation+enroll+
  explicit native start. Different lifecycle guarantees are visible.
- `submit_ns`: creation and joining of the same number of
  producer threads, equal successful admissions and rejection
  retries; includes some concurrently executed worker work.
  This **is not** a pure manager mutex latency microbenchmark.
- `join_release_ns`: original/P23 actual `closeAndJoin()` or
  P29 handoff+actual join+checked `GC.removeRoot`.
- `total_ns`: all timed phases above, excluding common per-arm
  `PerfReceipt` preparation, a preceding `GC.collect()`, input
  parsing and CSV I/O.

`producer_alloc_bytes` sums deltas of
`GC.allocatedInCurrentThread()` on the producer threads.
It does **not** measure full live heap, process RSS or native
scheduler allocations. The benchmark does not claim RSS figures.

All three modes run within each triplet. **Following the
2026-10-15 XPS baseline**, the order uses the balanced cyclic
Latin square `m0→deferred→managed`,
`deferred→managed→m0`, and
`managed→m0→deferred`. Each mode occupies each position
exactly once in every block of three triplets; an always-evaluated
test checks that property. The archived first XPS run used the
older imbalanced order and must not be retroactively described as
balanced.
Warm-up pairs are recorded separately and excluded from
medians. Results are compared **per-round under the same workload**,
not from unrelated independent batches.

## Tooling and quality gates

- [`m1_p30_benchmark_probe.sh`](../../../../tools/research/m1_p30_benchmark_probe.sh):
  DMD/LDC debug and whole release, plus LDC debug `-O3`;
  small bounded correctness workloads. No speed threshold.
- [`m1_p30_analyze.py`](../../../../tools/research/m1_p30_analyze.py):
  CSV structure validation; no duplicate or missing arms;
  exact equality of dimensions, acceptance/completion and
  checksum; monotonic/non-negative timing fields and phase sums;
  per-round diagnostic medians/ratios with a synthetic
  **positive+negative** self-test.
- [`m1_p30_xps.sh`](../../../../tools/research/m1_p30_xps.sh):
  **real machine capture only**, optimized whole-release LDC,
  three workloads, three warm-up triplets and nine measured
  triplets per workload, machine/compiler/commit/governor
  metadata, raw CSV and JSON summaries.

From a clean repository checkout on the target XPS:

```sh
bash tools/research/m1_p30_xps.sh
# Or provide a destination:
bash tools/research/m1_p30_xps.sh "$HOME/Downloads/p30-ownership"
```

The script writes each workload's `.raw`, `.csv`,
`-analysis.txt` and `-summary.json`, plus `metadata.json`,
into the selected external output directory (outside the
repository). The three workloads cover one, two and four
simultaneous producers with fixed same-work dimensions **within
each** paired triplet. All loops, native joins and controller
roots remain real.

**Do not infer a result from an unrun XPS script.**
Before interpretation, preserve raw CSV and host metadata,
check CPU thermal throttling, frequency/governor variation,
background competition, compilation flags, sample variance
and possible GC interference. Repeat runs under matched
thermal conditions. Compare with C++ only after matching
ownership/lifetime semantics and the same TaskRef work; no
"native C++ parity" claim is made here.

## First native XPS evidence (historical unbalanced baseline)

The user-supplied archive `concurrency-p30-xps-20261015T134105Z.tar.gz`
passed independent SHA-256 verification
(`2252c2b81b7d5894578dd3dc82158c2a83763f78a592a4f17b6a2bb1af9b14c3`).
The original measurement ran at
[`33d4e17b`](https://github.com/alex-1974/concurrency-d/commit/33d4e17b088460bd0489688af6482eb2d560ae9b)
on an i7-9750H XPS 15 with LDC 1.41.0.

[Full measured evidence and limitations](evidence/xps-2026-10-15-results.md)
preserve the nine-round median submission times and paired ratios,
the position-imbalance discovery, source pins and the decision to
retain P29's safety machinery until a balanced repeat.

The first XPS benchmark does **not** establish a stable P29
throughput penalty. The larger concern is the poor multi-producer
profile throughput in all three implementations; that mechanism
needs isolation under fixed task/worker dimensions.

## Balanced repeat received — 2026-10-15

A second **SHA-256 verified** XPS measurement was supplied on
[`eacbe9a1`](https://github.com/alex-1974/concurrency-d/commit/eacbe9a1f63d51a873ce1e40ae86e7198cac7557)
using the corrected arm order. The [balanced-repeat analysis](evidence/xps-2026-10-15-balanced-results.md)
preserves its archive checksum, matched-worker/task preflight and
paired nine-round comparison against the
[original order-imbalanced baseline](evidence/xps-2026-10-15-results.md).

In balanced measurements, paired P29/P23 submission ratios for
1/2/4 producers are **1.022/1.017/1.012**. Per-round signs are
6/9, 5/9 and 5/9 slower, with ranges crossing 1. These findings
do **not** isolate a stable per-submission manager-lock penalty or
justify weakening P29 ownership correctness. The 4-producer
profile also doubles workers and task count, so P31 must hold
those dimensions fixed before diagnosing scaling.

## P31 controlled producer follow-up

[P31](../p31_fixed_producer_scaling/README.md) addresses the confounded producer profiles in the two P30 XPS captures. It retains the exact original M0 scheduler and P29 owner manager while fixing total TaskRefs, workers, ingress and retention across **1/2/4 producers**. It compares a task with two shared atomics against a task with two producer-sharded atomics and a minimal-return task, each under the original M0, direct P23 and managed P29 ownership paths.

This protocol does not assume the P30 profile slowdown was caused by the P29 manager Mutex or by shared task counters. P31's work variants are mechanism diagnostics; only owner modes *within the same work variant* have equivalent task semantics. An actual optimized XPS run is required before any numerical conclusion.

## Decision status

**KEEP as a benchmark harness, not yet a performance verdict.**
P29 correctness/ABA proof remains the reference for the
generation-tagged lifecycle; P30 isolates how much that
implementation costs for the matched task stream but does
not qualify new `@safe` caller lifetimes, native fault
recovery or arbitrary owner handles as unforgeable tokens.

If optimized XPS results show meaningful per-submission
contention, first investigate whether the manager can
issue a checked owner lease once per **submission batch**
without invalidating the generation/reclamation contract.
Do not remove root checks to chase throughput. Retain
P29 as the control until an alternative passes equal
correctness and release-mode benchmarks.

**Code/CI checkpoint:** [`b69b8b3e`](https://github.com/alex-1974/concurrency-d/commit/b69b8b3e9383a9cbe58422c3f318c1ced2007e47).
[CI #38739901675](https://github.com/alex-1974/concurrency-d/actions/runs/38739901675).
Verify actual CI outcome before marking the benchmark gate
qualified; no native XPS archive is present in this PR.

Issue #17 remains OPEN, ADR-0001 PROPOSED, PR #38
Draft. Original M0 source and grandfathered PR #35 untouched;
no merge to `develop` or `main`.
