# R0.5 — Owned-task storage: paired end-to-end qualification

**Status:** experimental candidate; **NO selected production storage policy**.
Tracking: [#20](https://github.com/alex-1974/concurrency-d/issues/20).
Preserves the public-API and scope/lifetime questions in [#11](https://github.com/alex-1974/concurrency-d/issues/11) and [#17](https://github.com/alex-1974/concurrency-d/issues/17).

## Measured question

With **identical callable, retention budget, ingress size, result-cell and
exception contract, and worker count**, how much does typed recycling of
concrete owned task records change end-to-end cost relative to allocating
a fresh GC node on every accepted task?

Two internal policies:

- `freshGc` (baseline): each submission creates a new GC-managed
  `OwnedNode!(F,R)`; completed strong roots are dropped by the existing
  post-dispatch reclaimer.
- `recycleTyped` (candidate): after the same post-dispatch release marker,
  the executor moves a completed node into a bounded spare cache and
  rearms it only for the **exact same concrete F/R layout**. It creates a
  fresh node if no type-compatible spare exists.

Both policies still create a **new GC-managed ResultCell and TaskHandle per
submission**; old handles are not repurposed and can be observed after
the underlying record has been reused. Neither changes the 8-byte
`TaskRef`, user-callable execution attributes, bounded admission, result
wait, error delivery, or draining shutdown.

The spare-cache size is capped by `maxRetained`. The cap controls the
number of simultaneously in-flight records; spare nodes can add up to
another budget's worth of strong roots. All roots are cleared after join.
`recycleTyped` currently uses D dynamic class casts to select a
compatible spare, which is intentional instrumentation rather than an
assertion of final hot-path optimality.

## Reproduce

From the `concurrency-d` repository root:

```bash
dub test --compiler=dmd --force
dub test --compiler=ldc2 --force

# Basic paired GC vs typed recycle test (4 budgets × 2 policies)
dub run --config=task-pipeline-benchmark --compiler=ldc2 --build=release --force -- 4 20000 5 scalar

# Wider GC-visible closure and void task contracts
dub run --config=task-pipeline-benchmark --compiler=ldc2 --build=release --force -- 4 20000 5 all

# Preferred: each scenario/budget/policy gets a fresh Linux process;
# results include per-run peak RSS and paired median speedups.
python3 tools/research/r05_pipeline_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=20000 --rounds=5 \
  --scenarios scalar wide void --budgets 8 64 512 4096 \
  --output=evidence/r05-local-xps
```

Arguments: `workers tasks per-case-rounds scalar|wide|void|all`.
The benchmark uses the retention budgets **8, 64, 512, 4096** and runs
both policies for every budget, alternating order by round.

### What is included

- An explicit executor and its worker start and draining shutdown;
- per-task callable preparation and owned record/result-handle creation;
- bounded external ingress, worker queueing/stealing/parking, dispatch;
- worker completion and post-dispatch record marking;
- producer-side root compaction on budget pressure, optional typed-node reuse;
- successful completion of every accepted task;
- real result observation via `TaskHandle.get()` for every 17th task;
- an observable atomic counter increment on every task;
- dropped handles for the remaining tasks.

Scenarios use a scalar-value callable, a 256-byte payload callable holding
a string, and a `void` callable. Fresh and recycled policies execute
**the same scenario**; comparisons across *different* scenarios are not
intended as equal-work performance claims.

### Metrics

Each CSV row reports: wall-clock total milliseconds, throughput
(tasks/s), fresh concrete-node construction count, reused-node count,
GC bytes allocated **in the producer thread** during the run,
GC heap used-size delta, and observed-handle count.

The producer allocation counter does not measure the allocations of
worker threads, and the GC heap used-size delta is **not peak RSS**.
Both numbers are diagnostics, not a proof of total memory retention.
No allocator-only microbenchmark is presented as end-to-end performance.

CI compiles/tests on DMD 2.111 and LDC 1.41 (x86-64) and native ARM64
LDC, then prints a short two-policy diagnostic with 768 tasks.
A separate R0.5 research-evidence workflow executes a 3-round, 6000-task
matrix on LDC/x86-64 and native LDC/ARM64 and uploads raw and summarized
CSV evidence. That matrix launches **one new Linux process per case**,
collects per-child peak resident memory through `wait4`, and reverses
the paired policy order between rounds. This is necessary because
`ru_maxrss` observed from a single continuing process cannot decrease
after an earlier larger benchmark case. The matrix CSV contains peak RSS
in Linux KiB. The runner still introduces scheduling and thermal noise.
Hosted runner numbers do **not** constitute a numerical performance
quality gate and should not be ranked across dissimilar hardware.
Repeat the optimized LDC runs on a controlled XPS before a policy
selection; include run-to-run variation, CPU/power state and allocation
count in the decision.

## Correctness and scope

- A node is moved to spares only after the post-dispatch marker is visible
  with acquire ordering. The worker has already finished task completion
  accounting and will not dereference this TaskRef again.
- Reuse sets a *new* record result-cell, callable and completion marker
  before re-submission; old TaskHandles own distinct cells.
- User callables with borrowed local references remain explicitly
  `@system`: this candidate does not grant a new `@safe` contract.
- The cache is internal and reversible; `freshGc` remains the default.
- Non-copyable/move-only `F`/`R`, negative lifetime tests, destructor
  semantics, and sustained multi-producer cache contention need independent
  qualification before claiming general task-storage coverage.

## Decision gate

Measure before selecting KEEP/REJECT/DEFER for typed recycling.
For a production choice, require consistent optimized LDC wins at
equivalent correctness and memory semantics on realistic workloads,
no unacceptable peak-retention increase, and review the additional
type-matching and control-plane complexity. Do not infer a C++/Rust
performance comparison from these two D variants alone.
