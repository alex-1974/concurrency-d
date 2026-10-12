# R0.5 — Storage comparisons after the full-victim production fix

**Status:** research-only scheduler-baseline reconciliation, **not** a
storage-policy selection or a change to `develop`.

**Tracking:** [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20),
grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35),
merged production [PR #37](https://github.com/alex-1974/concurrency-d/pull/37).

## Why a new research baseline is required

On 2026-10-12, `develop` accepted the narrow complete-foreign-victim
scheduler fix as the squash commit
`7af4409a2e09a303dfbc6c54033d28c92eb67581`.
The existing R0.5 research branch predates that merge. Its normal
`task-pipeline-mixed-benchmark` build still uses the original **N−1
candidate-slot** search, which could skip one foreign deque before
parking. Previous XPS GC-vs-recycle studies used that historical
scheduler and must **remain historically attributed to their original
Git SHAs**. It would be misleading to call their default scheduling
the current `develop` baseline.

The research branch already contains **two separate DUB configurations
that execute the same `multi_producer.d` consumer**:

| Research `--victim-sweep` | DUB configuration | Code behavior |
|---|---|---|
| `full` (**new research-runner default**) | `task-pipeline-mixed-full-victim-sweep` | `R05FullVictimSweep`; N candidate slots, skip self, N−1 foreign victims |
| `legacy` (**historical control**) | `task-pipeline-mixed-benchmark` | pre-PR37 N−1 candidate slots, skip self; may omit a foreign deque |

The change is to **the Python research runner's configuration selection,
not the scheduler implementation or DUB configurations**. The two
storage policies, `gc` and `recycle`, use **the identical compiled
executable and scheduler setting within every pair**. The historical
configuration remains directly executable using
`--victim-sweep=legacy` without rebasing, rewriting, renaming or
deleting historical evidence.

The opt-in `R05RotatingFullVictimSweep` remains a **separate rejected/
deferred research variant**; it is deliberately not introduced into
the storage comparison. This research runner does not change
`freshGc` as production default, batch8, notification policy,
typed result cells, TaskRef layouts, GC roots, bounded admission,
shutdown or task lifetime. The research branch contains additional
R0.5 experimental mechanisms, so **equivalent victim scan alone does
not make the R0.5 executor identical to M0 on `develop`**.

## Reproducibility

`tools/research/r05_mixed_producer_matrix.py` now:
- explicitly selects the scheduler DUB configuration, default `full`;
- records `victim_sweep` in each raw case and summary group;
- records the DUB configuration, research HEAD and reference production
  fix SHA in `environment.txt`;
- preserves **fresh Linux process per case**, paired round/policy order,
  per-child peak RSS via `wait4`, producer GC allocations, typed-node
  creation/reuse, and exact task completion for every case.

This is a **new version of the research protocol**. Pre-existing raw
CSVs without a `victim_sweep` column are unmodified and describe
their original commits; do not append them blindly to post-change
summaries or call them `full` data.

## Native XPS follow-up — full scan first

On the Dell XPS, preserve any local work before switching branches:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_mixed_producer_matrix.py \
  --compiler=ldc2 --victim-sweep=full \
  --workers=4 --tasks=100000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --output=evidence/r05-post-pr37-full-storage

tar -czf r05-post-pr37-full-storage.tar.gz \
  -C evidence r05-post-pr37-full-storage
```

This gives 5 rounds × 3 producer counts × 2 budgets × 2
storage policies = **60 independent process runs** with six million
tasks in total. Do not compare these absolute throughput numbers
directly with the prior short R0.5 XPS runs that differed in
task count, governor/activity and sometimes benchmark-instrumentation
settings.

**Optional diagnostic control** only if post-fix effects suggest
scheduler sensitivity, using the identical workload and an
explicitly separate output path:

```bash
python3 tools/research/r05_mixed_producer_matrix.py \
  --compiler=ldc2 --victim-sweep=legacy \
  --workers=4 --tasks=100000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --output=evidence/r05-post-pr37-legacy-control
```

Comparisons across `full` and `legacy` are **diagnostic
interactions**, not paired same-binary storage comparisons. No
performance difference is known yet from the new XPS corpus.

## Gates and decisions

1. Verify every raw row has the correct `victim_sweep` and
   `completed == tasks`, each pairing contains exactly `gc`
   and `recycle`, and node creation/reuse accounting is coherent.
2. Separate ingress contention (1 vs 4/8 producers) and budget
   pressure (8 vs 512) from recycling cost. Include paired
   throughput ratios, producer GC bytes, `wait4` RSS and
   run-to-run scatter.
3. Do **not** claim that reducing GC node creation proves reduction
   of total GC allocation or retained memory: both policies still
   allocate result cells and task handles.
4. Keep move-only, destruction, GC-visible closure and lifetime
   qualification open in [#17](https://github.com/alex-1974/concurrency-d/issues/17);
   the present benchmark is not a `@safe` cross-thread capture
   guarantee.
5. **KEEP `freshGc` in normal code, DEFER `recycleTyped`** pending
   controlled native evidence and closure/lifetime qualification.
   Neither `develop` nor any other repository is modified.
6. The grandfathered PR #35 remains Draft and is not wholesale
   merged into `develop`. Its baseline branch predates PR #37;
   reconcile destinations explicitly under the workspace
   grandfather/transition policy before any further promotion.

The primary intent is to keep **future research semantically aligned
with the accepted victim-coverage rule while still reproducing the
historical old scheduler**.
