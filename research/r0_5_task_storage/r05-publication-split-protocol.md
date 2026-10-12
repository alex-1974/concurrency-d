# R0.5 — Publication split: GC-root append vs inbox submit

**Status:** Opt-in research implementation, DMD/LDC x86 and native ARM64 correctness/format gates **PASS**. **No new native Dell XPS publication timings yet.** This study is a continuation of the [native admission-stage result](results/xps-admission-stages-review-2026-10-12.md). The grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35) and [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20) retain the research history; `develop` already contains the independent full-foreign-victim correction via merged PR #37.

## Narrow hypothesis and boundaries

The previous XPS experiment measured the broad `publish` stage at roughly 58–63% of the **instrumented** producer admission mutex hold time. That bracket consists of precisely:

```d
_retained ~= RetainedTask(node, node.returnedFlag());
const status = _pool.trySubmit(node.reference());
```

The first operation appends a **strong GC root** to the executor's retained array (including D dynamic-array management). The second calls the submission pool's inbox. The inbox implementation takes a **separate inner mutex**, verifies space/closure, enqueues the borrowed task reference and may call `Condition.notify()` for the current `always` notification policy.

**The existing result did not identify** which of those two operations dominates. This opt-in change adds only timers/counters around the two original statements, without splitting or reordering the locks, changing root registration or publication order, changing notification policy, moving allocations or modifying the accepted/rejected TaskRef contracts. The normal uninstrumented `submit` codepath still has no new probes.

## What the new numbers mean

With the *existing* `R05AdmissionStageProbe` compile-time DUB configuration `task-pipeline-mixed-full-victim-admission-stages`, each producer's private `AdmissionProbe` now also records:

| Field | Measured boundary | Denominator |
|---|---|---|
| `root_append_count`, `root_append_ns` | `_retained ~= RetainedTask(node, node.returnedFlag())` | Accepted submission attempts |
| `inbox_submit_count`, `inbox_submit_ns` | `_pool.trySubmit(node.reference())` | Accepted submission attempts |
| `publish_count`, `publish_ns` | **Whole existing publish bracket**, including both new clocks/counter updates | Accepted submission attempts |

All three counts must equal the number of accepted tasks on the current fully-completing mixed benchmark, while `gate_count == attempts == tasks + rejected_retries`, `cell_count == node_count == tasks`. The benchmark rejects discrepancies **at runtime in release builds**, and the Python driver independently validates the same counts.

The measured total `publish_ns` is **not simply the sum** of `root_append_ns` and `inbox_submit_ns`: it also encloses timers, increments, result transformations and instruction gaps. All numbers include profiler overhead and scheduler/GC preemption. The driver separately retains `root_over_publish_diagnostic` and `inbox_over_publish_diagnostic` as descriptive ratios only, **not causal speedup contributions or calibrated shares of uninstrumented time**.

`inbox_submit_ns` groups **nested-inbox mutex acquisition + enqueue + wake notification**; it is **not** separately a measurement of `Condition.notify` nor a pure mutex-wait benchmark. If its cost is material, the next study could split that path further behind a different, narrowly scoped compile-time probe, but only after native XPS evidence.

The previous stage/lock metrics remain: `gate` (including rejected attempts before allocations), `cell`, `node`, overall `publish`, admission mutex `wait_ns` and `hold_ns`, `wait_p95_upper_ns` and `hold_p95_upper_ns`, child-process `wait4` RSS and producer-thread GC allocation. The log2 p95 values are **bucket upper bounds**, not exact quantiles.

## Reproducible native Dell XPS experiment

Use the existing local repository checkout, previously at `~/Programmiersprachen/dlang/concurrency-d`. Inspect and preserve local changes/untracked research assets before switching the grandfathered research branch.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_admission_stage_matrix.py \
  --compiler=ldc2 --workers=4 \
  --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --workload=minimal --counter=shared \
  --output=evidence/r05-xps-publication-split

tar -czf r05-xps-publication-split.tar.gz \
  -C evidence r05-xps-publication-split
```

On AC power without heavy background load, this produces **120 independent processes and 3.6 million completed tasks**: 5 rounds × 3 producer counts × 2 budgets × 2 policies (`freshGc`, `recycleTyped`) × 2 separate configurations (unprofiled `off`, profiled `on`). Source `environment.txt` includes checked-out HEAD, compiler and DUB versions, `lscpu` and governor snapshot (not sustained clock/temperature trace).

Expected outputs (identical file identities to previous stage study, **new versioned schema**):
- `raw.csv`: 120 scenarios, stage and new nested publication counters only in `on` rows;
- `pairs.csv`: 60 matched same-round GC/recycle throughput ratios, each comparing **the same instrumentation mode**;
- `diagnostics.csv`: 60 profiled per-policy cases, with both root and inbox nanoseconds per accepted task, their diagnostic ratios and admission wait/hold/retry counts;
- `summary.csv`: 12 grouped paired throughput summaries with 5 rounds each;
- `environment.txt`: source/compiler/governor provenance and measurement warnings.

**Do not merge** previous `r05-xps-admission-stages` raw CSV rows into the new schema. The source revisions and number of timers differ and the new profiling inherently perturbs the timings. Preserve both original archives and source-identified reports.

## CI and promotion conditions

The updated stage validation workflow [run #38253380069](https://github.com/alex-1974/concurrency-d/actions/runs/38253380069) **PASS** on DMD 2.111 x86-64, LDC 1.41 x86-64 and native LDC 1.41 ARM64. CI checks default GC and typed-recycle completion, rejections-before-allocation, all stage/substage counts, elapsed bounds, separate uninstrumented build, paired CSVs and unique cases. Hosted timings are not a speed gate.

Native evaluation should answer:
1. Does `root_append_ns` or `inbox_submit_ns` dominate the **instrumented** combined publication bracket, and how consistent is that observation over 5 rounds and 1/4/8 producers?
2. Is the observed difference compatible with (or perhaps confounded by) increasing producer lock waiting/retries and OS scheduling? Does any substage pattern survive GC/recycle and both 8/512 retention budgets?
3. Do `off` GC/recycle throughput ratios qualitatively agree with the prior full-victim native XPS results, without declaring a cross-campaign exact percentage agreement?
4. If inbox submit dominates, **measure** nested mutex wait versus enqueue/notify in another narrowly scoped experiment before changing it; do not prematurely introduce a lock-free queue or remove the wake-generation predicate.

**Decision until new native data:** keep `freshGc` default, typed recycling optional/research-only, PR #35 Draft, Issue #20 open. The production scheduler fix on `develop` and other repositories remain unchanged. No API, lifetime, ownership or memory-model contract is promoted by this probe.
