# R0.5 — Same-binary shared-vs-striped execution counter A/B

**Status:** isolated, research-only *benchmark-confounder* qualification.
No new production scheduler algorithm, GC storage policy, public API,
lock or notification semantics. Track [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20),
grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35).

## Why this discriminator is required

The immediately previous native [uninstrumented XPS CPU and scheduling
report](results/xps-native-system-cpu-scheduling-review-2026-10-12.md)
showed that, on the same R0.5 full-victim research scheduler with
four workers, increasing concurrent producers from 1 to 4/8 reduced
compute-1024 end-to-end throughput by about 44% and greatly increased
whole-process CPU seconds/Task and voluntary context switches/Task.
The test used the benchmark's **shared atomic execution counter**.
Without a direct same-binary alternative, it is premature to call
the negative scaling exclusively a scheduler admission problem.

The benchmark already implements a selectable `shared` vs `striped`
execution-counting mode in `multi_producer.d`:

```d
auto target = striped ? &stripes[i * 16] : &executions;
```

All three Task-callable families increment the selected counter once
on actual execution via the **same atomic RMW**. The striped layout
provides **16 `ulong` slots (128 B) between each originating
producer's counter**. It is **NOT** a per-worker counter: tasks
created by one producer may run on different workers, which still
contend on that producer's stripe. The `admitted`, `observed`
and void-work `computeChecksum` atomics are still shared; result
handles and typed task semantics remain unchanged.

A single producer is **not a guaranteed no-op control** for stripes:
the shared and striped counters have different storage addresses
and potentially different cache/GC placement even with only one
producer. The controlled question is therefore the *measured
magnitude and producer-count interaction* of this existing
benchmark detail, not the theoretical cost of a single isolated
atomic increment.

## Protocol and independent evidence

New Linux runner:
`tools/research/r05_counter_contention_matrix.py`.
It deliberately reuses the externally verified
`build()`/`run_child()`/resource parsing of
`tools/research/r05_native_cpu_profile.py`.

- **Build once** with DUB release configuration
  `task-pipeline-mixed-full-victim-sweep`, only the
  `R05FullVictimSweep` compile-time version. Reuse the **exact
  same binary SHA-256** for every process and both counter modes.
  No stopwatch, parking profiler, inbox profiler, `perf` wrapper
  or changed notification policy; explicitly pass
  `instrumentation=off`, `parking=off`, `notify=always`.
- Same task IDs, deterministic minimum and compute-1024 workloads,
  same typed/GC-reachable/void callable mix, actual result
  observations, bounded ingress, retention budget, accepted/completed
  checks, and `freshGc`/`recycleTyped` policies within each pair.
  Compute checksums and task accounting are verified by the D
  consumer and across all fresh processes.
- **Adjacent same-round counter-mode pairs** for each workload,
  producer count, budget and policy; alternate which counter mode
  executes first based on round/factors. GC/recycle policy order
  also alternates. A fixed post-process cooldown is outside
  the child's measured work.
- Record per-process `wait4` user/system CPU, voluntary/involuntary
  context switches, external wall, peak RSS, producer-only resource
  totals, internal throughput, task counts, source HEAD,
  compiler/toolchain/governor information and binary SHA.
  Frequency/power/thermal snapshots are **not** controlled average
  clocks. The prior XPS `perf stat` preflight failed under
  `perf_event_paranoid=4`; this driver **does not attempt perf** or
  change host security settings.
- Separate the per-round **striped/shared** throughput ratio
  (`pairs.csv`) from independently displayed per-mode median
  rates. For each mode also calculate 4/1 and 8/1 producer
  throughput ratios within one round/GC policy/workload
  (`producer_scaling.csv`): these are **nearby sequential**
  trials, not simultaneous experiments or guaranteed
  correction for time drift.
- Keep `producer_scaling_summary.csv` distinct and avoid
  presenting the two counter layouts as two different
  scheduler implementations. Neither a positive nor a negative
  result alone proves an intrinsic architecture bottleneck.

The default native matrix has **10 rounds × 2 workloads ×
3 producer counts × 1 budget × 2 storage policies × 2 counter
modes = 240 independent child processes**, **30,000 completed
Tasks per child = 7.2 million actual Tasks**. This gives
10 within-round counter pairs per factor group (12 factor groups),
and per-mode 4/1 and 8/1 controls, double the previous
five-round sampling depth. The original XPS campaign (shared-only)
is **historical contextual evidence**, not iid extra rounds
or an exact current-source comparison.

## Dell XPS native execution

Use the existing local checkout; previous reports place it at
`~/Programmiersprachen/dlang/concurrency-d`. Inspect/safeguard
local tracked and untracked research evidence before changing branches.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_counter_contention_matrix.py \
  --compiler=ldc2 \
  --workers=4 --tasks=30000 --rounds=10 \
  --producers 1 4 8 --budgets 512 \
  --policies gc recycle --workloads minimal compute \
  --cooldown-ms=100 \
  --output=evidence/r05-xps-counter-contention

tar -czf r05-xps-counter-contention.tar.gz \
  -C evidence r05-xps-counter-contention
```

Run on AC power with minimal competing load, **without manually
changing governor, perf access controls or CPU affinity**.
Keep the output directory source-pinned and do not overwrite
previous native research. The expected files are:

| File | Meaning | Expected row count |
|---|---|---:|
| `raw.csv` | 240 process results, all six factors | 240 |
| `pairs.csv` | within-round striped/shared throughput, CPU/switch diagnostics | 120 |
| `summary.csv` | 10-round paired ratios/wins by workload/producers/policy | 12 |
| `producer_scaling.csv` | per-mode 4/1 and 8/1 producer diagnostic ratios | 160 |
| `producer_scaling_summary.csv` | per-group 4/1 and 8/1 median scaling | 16 |
| `environment.txt` | source/compilation/governor/binary identity and limitations | — |

The default matrix includes **120 paired counter comparisons**
(10 rounds × 2 workloads × 3 producer counts × 2 policies),
**12 paired-summary groups**, **160 producer-scaling
comparisons** (10 × 2 workloads × 2 policies × 2 modes ×
2 target producer counts), and **16 producer-scaling-summary
groups** (2 workloads × 2 policies × 2 modes × 2 target counts).

For a strict gate all rows must be present with no duplicated
factor key; in each pair task count, checksum, binary hash,
notification/worker/retention settings are identical and
only counter mode differs. The consumer checks `executed =
accepted = completed = tasks`, all observed typed results and
GC-visible/void tasks. The Python driver checks agreement of
the returned deterministic checksum across all modes and
scenarios of a given workload.


**Protocol accounting correction (2026-10-12):** Earlier versions of
this document mistakenly counted only one counter mode per scenario
and claimed 120 children / 3.6M Tasks and 60 striped/shared pairs.
The executable driver and original user evidence actually run **both**
shared and striped in a separate fresh process for every scenario:
**240 children / 7.2M Tasks and 120 pairs**. The source data and
runner were not altered by this documentation correction.

## How to decide

1. **Large striped/shared improvement, especially at four/eight
   producers:** strong evidence that the shared atomic execution
   counter is a meaningful **benchmark confounder**. Repeat
   scheduler comparison in striped mode before assigning the
   former throughput loss to admission serialization. Do not
   claim that `striped` is intrinsically the best consumer
   counter or that the scheduler became faster.
2. **Little/no counter difference but negative producer scaling
   in both:** benchmark output counter is unlikely to be the main
   driver in this workload. Proceed to a new externally observed
   per-thread scheduling/bottleneck test, with no premature mutex
   replacement, and preserve both CPU/switch evidence and the
   earlier notification-policy negative result.
3. **Mixed/reversing differences across workload/producer/policy:**
   maintain an explicit workload-dependent interpretation and
   improve native repeatability before selecting a mechanism.
4. **One-producer modes differ:** report independently as a
   memory-placement/control observation; do not zero-normalize
   away their actual absolute throughput or treat their
   difference as measurement error by definition.

**No automatic promotion:** keep `freshGc` and
`NotificationPolicy.always`; `recycleTyped` and all typed
spare-cache/lock-free inbox alternatives stay experimental.
PR #35 stays grandfathered Draft, Issue #20 open;
`develop` and other workspace repositories untouched.
