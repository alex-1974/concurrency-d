# M0 final compute-throughput gate — direct develop vs Draft PR #37

**Status: native Dell XPS measurements requested, NOT a performance verdict.**
This is a focused follow-on to the [original XPS direct M0 review](results/m0-xps-victim-coverage-review-2026-10-11.md)
and the [20-round wake retest](results/m0-xps-victim-wake-followup-review-2026-10-12.md).
Those prior native runs found a mixed-workload total median fix/base of
~0.9868× with significant control noise, and did **not** reproduce the
initial apparent 4-worker p95 wake penalty. The remaining gate concerns
sustained throughput with four workers and four concurrent producers.

## Exact comparison, no policy or semantic changes

| Side | Exact SHA |
|---|---|
| `develop` borrowed-task M0 baseline | `822a866d866dbb176f5435a41b09d189b8d0c4cb` |
| Draft PR #37 full foreign-victim coverage | `31f97b8315980b4b52a97cb1706a507a1422eaa5` |

Run [the paired two-worktree harness](../../tools/validation/m0_victim_coverage_xps.py)
from `validation/m0-victim-coverage-xps` (the linked runner is under
`tools/validation` from the repository root). Both pinned SHAs receive
an identical copied M0 borrowed-TaskRef benchmark and identical injected
DUB release build config. The runner requires matching DUB dependency
selections, accepts results only if counts and checksums match, and records
within-round A/B or B/A order with exact round/worker/producer/workload
identity. All worker, producer, capacity and task-body settings are
**equal** in both executables.

The benchmark has no R0.5 OwnedTask API, task-tracing mutex, experimental
rotation, changed queue primitive, or changed batch size.
It measures the entire multi-producer ingress/dispatch/close/join
interval; per-task result verification occurs **outside** that interval.
The long workload has **300,000 tasks per process**, each running a
deterministic 1,024-iteration kernel. Producer backpressure counts,
child CPU and context switches remain visible. The only scheduler
code delta is PR #37's N-slot victim scan and its tests.

## Native XPS protocol

Run on AC power, with no other heavy workload, preferably with the same
desktop session and power profile across all paired rounds. Do **not**
blindly force a governor, overclock, hotplug CPUs or alter kernel
tunables: the harness only observes. If power profile or cooling behavior
is modified deliberately, record what changed and why; do not compare
campaigns as if the environments were equal.

Check and preserve local changes before switching:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/concurrency-d
git status --short --branch
git fetch origin
git switch validation/m0-victim-coverage-xps
git pull --ff-only origin validation/m0-victim-coverage-xps
```

**Primary M0 long compute gate** (not an idle test):

```bash
python3 tools/validation/m0_victim_coverage_xps.py \
  --compiler=ldc2 --mixed-only --cpu-snapshots \
  --rounds=20 --tasks=300000 \
  --workers 1 4 8 --producers 4 \
  --workloads compute --compute-rounds=1024 \
  --budget=512 --cooldown-ms=100 \
  --output=evidence/m0-xps-final-compute-512
```

The 1-worker case is the single-worker **control**, 4 workers are the
**target**, and 8 workers are a scaling countercheck. All three
sweep an identical pinned scheduler source pair. The 1-worker fix
still executes one harmless self-skip candidate index, so its
performance change is a useful observable control, not asserted to
be exactly zero.

The **optional independent ingress-budget control** targets the
same 4-worker/4-producer case at capacity 4096. Do this only if the
first dataset shows a consistent deficit or producer retry cost that
could be attributable to bounded admission:

```bash
python3 tools/validation/m0_victim_coverage_xps.py \
  --compiler=ldc2 --mixed-only --cpu-snapshots \
  --rounds=20 --tasks=300000 \
  --workers 1 4 8 --producers 4 \
  --workloads compute --compute-rounds=1024 \
  --budget=4096 --cooldown-ms=100 \
  --output=evidence/m0-xps-final-compute-4096
```

**Preserve the complete unedited raw directory**, with `mixed.csv`,
`pairs.csv`, `control_pairs.csv`, `summary.csv`, `environment.txt`.
No idle.csv is produced in mixed-only mode. The separate capacity-4096
control is optional; its absence does not imply a passed gate.

Primary archival command:

```bash
tar -czf m0-xps-final-compute-512.tar.gz \
  -C evidence m0-xps-final-compute-512
```

Do not delete untracked benchmark or research files as part of this
experiment. The runner uses ephemeral temporary detached worktrees,
does not rebase, reset, merge, push or change permanent branches.

## Analysis and decision criteria

* **Correctness:** For every pair, all 300,000 tasks are accepted and
  completed exactly once, checksums agree, DUB resolution matches,
  and no run times out.
* **Primary target:** Per-round four-worker/four-producer compute
  `throughput_per_s` ratio `fix/baseline`, its median, direction
  counts, dispersion and absolute rates. Do not substitute
  `elapsed_ns` ratio without inversion: `fix/old throughput =
  old_elapsed_ns / fix_elapsed_ns`.
* **Controls:** Compare the same-round one-worker control and 8-worker
  countercheck, with absolute fix/base ratio **shown alongside** the
  optional control-normalized ratio. Normalization is diagnostic only
  and cannot excuse a consumer-visible slowdown.
* **Resources:** Processor user/system CPU time, voluntarily/
  involuntarily yielded context switches and producer ingress retries.
  `RUSAGE_CHILDREN.ru_maxrss` is cumulative and is **not** a
  valid per-case peak memory delta.
* **CPU environment:** `cpu_snapshot_median_khz_before/after`
  are instantaneous readings of available `scaling_cur_freq`
  files (not a per-run measured clock average and not guaranteed
  to represent thermal state), plus the operating-system/governor
  data in `environment.txt`. Frequency drift and OS scheduling
  are potential confounders even across paired rounds.
* **Fairness mechanism:** The separate R0.5 native three-blocker
  head-of-line experiment supplies the original evidence that N
  candidates stop the missed-victim problem. This compute test
  measures throughput; it does **not** reassert a general progress
  guarantee under fully blocked workers.
* **No artificial performance gate:** CI smoke validates
  executability/semantics/format on DMD and LDC x86-64/ARM64;
  CI runner wall-clock differences do not determine native performance
  acceptance. Interpret small shifts against the independent
  one-worker control and system drift.

**Promotion rule:** If this sustained comparison shows no material
consumer-visible regression, close the open performance review via
an explicit assessment of the correctness benefit against residual
overhead. If the four-worker throughput deficit consistently exceeds
control/noise, investigate and amend the *small fix candidate* with
new exact-SHA evidence, rather than merging large R0.5 research history.
Until then **keep PR #37 Draft/unmerged, PR #35 Draft,
Issue #20 open, and `develop` unchanged**. No other repositories
are part of this work.
