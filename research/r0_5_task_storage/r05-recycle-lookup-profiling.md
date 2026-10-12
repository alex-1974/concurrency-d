# R0.5 — Typed spare-cache lookup profiling after PR #37

**State:** isolated opt-in research mechanism; no production algorithm,
ownership, task-result, GC, default storage or public API change.
Tracking: [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20),
grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35).
Baseline: [native full-sweep XPS GC/recycle study](results/xps-post-pr37-full-storage-review-2026-10-12.md).

## Question and limits

Why does a heterogeneous typed-node recycler substantially reduce
concrete node creation (92–99% in prior Dell XPS data) and observed
process RSS, but lose ~3% paired throughput in the minimal mixed-task
workload? The executor currently performs dynamic
`cast(OwnedNode!(F,R))` along a **linear `_spare` scan under the
producer admission mutex**.

**Measurement and attribution are separate questions.** Search cost is
only one possible contributor; the benchmark also pays for result
cells/handles, retention compaction, ingress publication, shared task
atomics, producer scheduling and GC runtime effects. A counter of
RTTI probes is not proof of their isolated nanosecond cost.

## Instrumented and uninstrumented builds

Both binaries use the same `R05FullVictimSweep`, already accepted
in production as the narrow PR #37 N-slot foreign-victim-coverage
fix. No legacy N−1 scheduler and no rotating policy is included.

| Diagnostic mode | DUB configuration | Behavior |
|---|---|---|
| `off` | `task-pipeline-mixed-full-victim-sweep` | Uninstrumented normal R0.5 research path; `submit`, no `AdmissionProbe` timing or lookup counters |
| `on` | `task-pipeline-mixed-full-victim-lookup-probe` | Compile-time `R05RecycleLookupProbe`; existing `submitObserved` producer-local mutex wait/hold profile; optional shared-executor lookup counters |

The `R05RecycleLookupProbe` version gates the **entire new code
and data structure** at compile time. No profiling arrays or
per-task timing calls are added to the `off` binary. With the
probe enabled, all writes to `RecycleLookupStats` occur **under
the existing admission mutex**. The struct is read only after
`closeAndJoin()`, under that mutex. No new hot-path atomic,
mutex or allocation is required for the statistics.

**Lookup events collected in the `on` binary:**
- `searches`: number of accepted recycling submissions that reached
  the spare lookup;
- `empty_searches`: scans with no spare nodes at all;
- `attempted_casts`: total dynamic casts attempted against cached
  nodes, including unsuccessful wrong-layout tests;
- `hits` / `misses`: matched nodes versus newly allocated nodes;
- `hit_index_sum` / `max_hit_index`: zero-based index and max
  of successful matches in the scanning order;
- `max_candidates`: largest observed spare-array length before scan;
- `lookup_ns` / `max_lookup_ns`: accumulated and worst-case elapsed
  **whole scan + rearm bookkeeping + counters** (clock calls included).

`attempted_casts / searches` estimates how many type tests were
needed per attempted reuse. This is an observed count; it does not
equate to cycles or isolate RTTI-cast latency. `lookup_ns / searches`
estimates instrumented scan duration, **not raw `cast` cost**.
`lookup_ns / admission_hold_ns` is only a same-instrumented-run
diagnostic: the denominator includes accepted and rejected attempts,
other protected work and admission instrumentation. It is **not**
an exact causal fraction of mutex contention or elapsed application
wall time. `R05RecycleLookupProbe` itself perturbs the measured path,
particularly for short tasks.

**Correctness invariants:** fresh GC performs exactly zero spare
lookups; for recycling with every task accepted, searches and
hits+misses match accepted count, hits match actual reused nodes,
attempted casts are bounded by candidate count/retention budget,
and all typed/void results and checksums must pass the existing
benchmark's runtime checks. Both policies must use identical
scheduler/counter/workload/producer/budget settings within each
matched pair. No GC-visible `@safe` capture guarantee is inferred.

## Reproduce on native Dell XPS

Use the existing repository checkout (its actual location may be
`~/Programmiersprachen/dlang/concurrency-d`, not the workspace/libs
example). Preserve unrelated untracked research assets.

```bash
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_recycle_lookup_matrix.py \
  --compiler=ldc2 --rounds=5 --tasks=30000 \
  --workers=4 --producers 1 4 8 --budgets 8 512 \
  --counter-mode=shared --workload=minimal \
  --output=evidence/r05-xps-recycle-lookup

tar -czf r05-xps-recycle-lookup.tar.gz \
  -C evidence r05-xps-recycle-lookup
```

The matrix contains 5 rounds × 3 producer counts × 2 retention
budgets × 2 storage policies × 2 diagnostic modes = **120 independent
Linux child processes**, each doing 30,000 tasks (**3.6 million total**).
The runner builds the two executable configurations with the same LDC
release compiler. Execution order alternates across pairs; every
child process is isolated and provides its own `wait4` peak RSS.

Files:

- `raw.csv`: all per-child accepted/completed, typed-node
  allocation/reuse, producer allocation and RSS; opt-in lookup and
  admission fields appear only for `on` cases;
- `pairs.csv`: same-round `recycle/freshGC` throughput ratios
  **separately for `off` and `on`**;
- `diagnostics.csv`: within-instrumented-case casts/search,
  hit location, admission hold/wait, retry pressure and lookup
  versus total hold time;
- `summary.csv`: five-round paired median throughput ratio and
  direction count per producer/budget/diagnostic mode;
- `environment.txt`: checked-out Git SHA, toolchain version,
  CPU/governor snapshot and exact workload settings.

Do **not** use `on/off` throughput as a new optimization
result. Its discrepancy shows measurement perturbation; no
unbiased profiler overhead correction is available. Also do not
pool these 30k-task scenarios with the earlier 100k-task XPS
data as though they shared identical conditions.

## Decision gate

Use the native **off** data to check whether GC/recycle throughput
remains directionally consistent with the earlier 100k-task study.
Use **on** data to find: (a) zero-hit vs matched-spare workload,
(b) average and worst successful match indices, (c) attempted RTTI
casts/task, (d) relationship between search time and instrumented
admission mutex hold/wait, and (e) sensitivity to budget 8 vs 512.

If most lookups examine one or very few entries and have low
diagnostic time share, a typified/indexed spare cache is **not**
yet a justified general rewrite. If casts/search scale materially
with candidate count *and* mutex hold cost, isolate an
index/compile-time-type strategy behind a separate opt-in
`research/` comparison while keeping the exact result, lifetime,
backpressure, GC and `@system` contracts. Do not assume
memory savings imply net throughput gains.

**KEEP normal `freshGc`; DEFER any recycler promotion.** This
experiment alone does not address move-only closures, destructor
semantics, GC-visible object tracing or task lifetime qualifications.
No wholesale merge of PR #35, no automatic `develop` writes.
