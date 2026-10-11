# M0 — Direct production fix vs develop performance validation

**Status:** reproducible qualification harness, **not** a production change
or a speed gate. Benchmark code and orchestration live exclusively on
`validation/m0-victim-coverage-xps`; the minimal production candidate
remains Draft PR #37 (`fix/full-victim-coverage`). The grandfathered R0.5
evidence and Draft PR #35 remain unchanged.

## Exact source comparison

| role | exact SHA |
|---|---|
| M0 `develop` (before) | `822a866d866dbb176f5435a41b09d189b8d0c4cb` |
| M0 coverage fix, PR #37 | `31f97b8315980b4b52a97cb1706a507a1422eaa5` |

Do not substitute the R0.5 OwnedTask executor as the baseline; it is a
different implementation with different storage and notification semantics.
The benchmark uses **only the M0 borrowed-TaskRef
`SubmissionWorkerPool`** with its existing batch8, FIFO ingress,
owner-only `containers-d` deque and epoch/Condition parking.

`benchmarks/m0_victim_coverage/main.d` is one shared independent
benchmark consumer. The runner pins each exact commit into a detached,
temporary worktree, copies exactly the same benchmark source into
both trees, and temporarily appends exactly the same external executable
DUB configuration. Neither existing source checkout is modified.
It builds both via the **same DUB release build and compiler**, and
refuses differing `dub.selections.json` resolutions. All temporary
worktrees are removed in a `finally` clause. No other repository is
read or written by the harness.

The producer benchmark allocates borrowed task records before timing,
creates the worker pool, then measures producer thread launch,
accepted submission, execution and close/join. Workloads are
zero-round `minimal` and deterministic 1024-round `compute` by
default. Each task stores a deterministic result and increments an
atomic execute counter; after measurement the runner verifies
**exactly once**, every result, the checked sum and
accepted/completed counts. On a full ingress, producers retry with
`Thread.yield`; their retry count is recorded. This is the
same producer/admission behavior on both commits.

Idle tests first create workers, then measure process CPU during a
quiet interval, and subsequently time one-at-a-time submissions
until each result is visible, including `Thread.yield` on the
controlling thread. They record wake response p50/p95/p99;
with 64 samples, p99 is **only that sample's maximum**, not
a statistical long-run latency claim. Whole-process CPU is
not worker energy or direct power consumption.

Independent cases: worker counts **1,2,4,8**,
producers **1,4**, both minimal/compute, five rounds and
100,000 tasks per mixed case. The 1-worker case is an independent
no-stealing control, not an expected performance win.
The runner alternates run order by round/factor, tests each binary
with a smaller mixed warmup and inserts a bounded cooling gap.
For fair performance qualification, run when the system is idle,
avoid other heavy workloads, and record CPU governor and thermal
conditions. No affinity or fixed clock is imposed automatically.

## Native Dell XPS instructions

From the `concurrency-d` repository, preserve any local edits:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/concurrency-d
git status --short --branch
git fetch origin
git switch validation/m0-victim-coverage-xps
git pull --ff-only origin validation/m0-victim-coverage-xps

python3 tools/validation/m0_victim_coverage_xps.py \
  --compiler=ldc2 --rounds=5 --tasks=100000 \
  --workers 1 2 4 8 --producers 1 4 \
  --workloads minimal compute --compute-rounds=1024 \
  --budget=512 --idle-ms=300 --wake-samples=64 \
  --gap-ms=1 --cooldown-ms=25 \
  --output=evidence/m0-xps-victim-coverage

tar -czf m0-xps-victim-coverage.tar.gz \
  -C evidence m0-xps-victim-coverage
```

Upload `m0-xps-victim-coverage.tar.gz`, including:
- `mixed.csv`: all individual before/after timings, retries,
  CPU, context switches, checksums and wall time;
- `idle.csv`: measured process idle CPU, wall interval and
  one-by-one result latency distributions;
- `pairs.csv`: within-round delta and fix/baseline ratios for
  identical factor sets, plus 1-worker controls;
- `summary.csv`: grouped medians of **paired** deltas/ratios;
- `environment.txt`: exact pinned SHAs, compiler version,
  benchmark SHA-256, hardware and CPU-frequency governor.

The runner does not merge, rebase, tag, or push.

## CI and production decision

CI on this validation branch executes a small correctness/portability
smoke of **both pinned M0 commits** on DMD 2.111 x86-64,
LDC 1.41 x86-64 and LDC 1.41 native ARM64.
Hosted-runner performance values are observations and are **not**
native Dell XPS verdicts.

The production loop's full foreign-victim coverage is mechanically
covered by deterministic tests (1–16 workers, all starts/self
indices) in Draft PR #37. The native XPS R0.5 mechanism
evidence is preserved separately in PR #35 / Issue #20.
The direct M0 test decides whether this tiny extraction has
acceptable total throughput, worker-count scaling, 1-worker
control movement and idle/wake behavior.

**KEEP PR #37 Draft until the exact candidate has both green
source tests and reviewed native direct comparison evidence.
Do not merge PR #35 wholesale. No changes to `develop`,
`main`, or any other repository.**
