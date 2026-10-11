# R0.5 admission and hot-atomic controls — hosted CI evidence 2026-10-11

**Status: experimental / profiling only.** The evidence does not justify
a production admission algorithm or record-pool change.

## Provenance

- Reference benchmark code head (the exact revision which ran):
  `5f7633239f0bf7ea0a187c090f867dcb4f4b864f`.
- [LDC 1.41 native x86-64 and ARM64 qualification](https://github.com/alex-1974/concurrency-d/actions/runs/38122552315):
  **PASS** for all two jobs. It includes the existing end-to-end
  workload, instrumented admission probe matrix and uninstrumented
  shared-versus-striped counter control.
- [DMD 2.111 / LDC 1.41 x86-64 and native ARM64 consumer matrix](https://github.com/alex-1974/concurrency-d/actions/runs/38122552388):
  **PASS** for all three jobs, including `submitObserved` compile/
  runtime and all accepted/completed result checks.
- Each CI runner executes four workers, 3,000 accepted tasks per case,
  two paired rounds, producer counts 1/4 and budgets 8/512. These are
  **not controlled Dell-XPS measurements**. Histograms include
  `MonoTime` clock and probe overhead. Separate uninstrumented control
  uses exactly the same task/output semantics with `submitObserved`
  disabled.
- [Uninstrumented control raw summary](./r05-ci-counter-control-2026-10-11.csv)
  and [profiled storage-policy summary](./r05-ci-admission-2026-10-11.csv)
  preserve the metrics printed by CI. Full per-run admission
  diagnostics (`raw.csv`, `summary.csv`, environment) are additionally
  attached to the workflow as limited-lifetime artifacts.

## Isolating the benchmark's shared execution counter

The primary comparison below keeps `freshGc` unchanged, switches only
one hot `shared(ulong)` atomic counter into producer-separated
128-byte-stride slots, and **does not enable admission timers**.

| Producers | Retention | LDC x86-64 striped/shared | ARM64 striped/shared |
|---:|---:|---:|---:|
| 1 | 512 | 1.0281× | 0.9912× |
| 4 | 512 | **1.2368×** | **1.0632×** |

For four producers, the GC-fresh baseline wins with separated counters
on both architectures (x86-64 2/2 pairs; ARM64 2/2 pairs). The
corresponding recycling-policy controls are **1.0053×** on x86-64 and
**0.9909×** on ARM64: there is no universal work-counter effect across
storage policies. The control does not remove the atomic increment:
each task still executes one, but writes from different producer
streams no longer collide on one cache line.

This is direct evidence that the *benchmark workload itself* adds
relevant synchronization costs, at least on some configurations.
It does not prove the admission mutex is harmless.

## Admission-mutex observations

On hosted DMD/LDC-compatible research binaries with admission
instrumentation enabled, two-producer/worker states vary, but the
four-producer cases show **approximate p95 upper-bin acquisition
waits around 131,071 to 262,143 ns** on many runs. The hold-time
p95 upper bins are **16,383 ns (native ARM64)** and **32,767 ns
(x86-64)** for those specific short CI samples. Quantile values
are **upper bounds of log2 bins**, not exact nanosecond percentiles.
Clock reads and histogram updates are included, so this data
localizes contention candidates rather than predicting unmodified
executor performance.

At budget 512, CI profile samples had **zero capacity retries**
even with four producers; lock acquisition delays can exist in the
absence of ingress/retention backpressure. At budget 8, retries
occur and vary between policies/rounds. The reporter separates
`retentionFull` versus `ingressFull` for later root-cause analysis.

## Accepted conclusions / pending evidence

1. **Keep `freshGc` as the default** on `develop`; the old Dell-XPS
   five-round series is valid but has a shared hot execution atomic.
2. **Do not infer a lock-free architecture requirement** from a
   four-producer benchmark alone: first rerun the XPS study using
   both counter distributions and timed admission.
3. **No general typed-node recycling promotion**. Both candidate
   performance and benchmark contention remain unresolved.
4. To analyze structural options, compare time per successful admission
   and lock p95/p99 while increasing producer counts 1/4/8.
   Account separately for failed admission attempts, `Thread.yield()`
   backpressure, and shared-counter cache-line contention.
5. Instrumented metrics may increase lock hold time. Compare
   `on` versus `off` throughput only to estimate instrumentation
   overhead, never as a code-speedup.

## Native XPS reproduction

From `~/Programmiersprachen/dlang/concurrency-d` on
`perf/r05-owned-task-pipeline` with LDC 1.41:

```bash
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only

# Admission-lock wait/hold, p50/p95/p99, per-producer retries:
python3 tools/research/r05_admission_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 64 512 4096 \
  --counter-modes shared striped \
  --output=evidence/r05-xps-admission

# Performance control without timestamping the admission hotpath:
python3 tools/research/r05_counter_control.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --policies gc recycle \
  --output=evidence/r05-xps-counter-control
```

Run both under documented CPU governor/power/thermal state; retain raw
and summary CSV and environment. Any subsequent structural improvement
must be compared at equivalent task/result/GC visibility semantics.
