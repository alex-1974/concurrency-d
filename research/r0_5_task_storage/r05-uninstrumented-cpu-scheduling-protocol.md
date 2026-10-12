# R0.5 — External CPU and scheduling qualification without hot-path probes

**Status:** research-only Linux runner; no executor/scheduler/GC/allocation
algorithm change. A complete native Dell XPS corpus from this runner
has **not** been collected yet. Grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35),
[Issue #20](https://github.com/alex-1974/concurrency-d/issues/20).

The immediate prior [native inbox study](results/xps-inbox-submit-review-2026-10-12.md)
found `Condition.notify()` took a median ~1.05 µs of
**instrumented producer-side call duration** under the inbox mutex,
but the measured inbox composite still contains substantial time
outside brackets. More importantly the **earlier native
waiter-aware policy A/B**
([report](results/xps-notification-ab-review-2026-10-11.md))
already failed to establish a general throughput benefit or conclusive
p99 wake-tail improvement. Therefore expensive `notify()` samples
are **not** permission to remove or coalesce notifications or to
introduce a lock-free queue.

## Question

Under an unchanged, uninstrumented full-victim R0.5 executable,
what does system-level CPU and context-switch evidence show at
1, 4 and 8 producer threads for representative short minimal
and compute-1024 task families? Do recorded process context switches,
producer CPU time and task throughput change with load in ways
consistent with outer admission serialization, worker scheduling
or GC activity? What do permitted kernel performance counters add?

**Scope is diagnostic correlation, not a causal intervention.**
Process context switches do not identify which mutex caused them.
Kernel `perf stat` event counts do not identify worker wake usefulness
or prove the next scheduler alternative will be faster. The benchmark
contains more synchronization than its admission and inbox locks,
including producer shared/striped counters, task result handles and
other GC operations.

## Implementation, preserved code contract

New driver:
`tools/research/r05_native_cpu_profile.py`.

- Compiles **only** existing DUB
  `task-pipeline-mixed-full-victim-sweep` with
  `--build=release`. No new D version or TaskInbox stopwatch is
  enabled. The full N-slot victim search follows the accepted
  coverage mechanism from PR #37, but this **R0.5 OwnedTask** code
  is not otherwise the M0 production implementation.
- Passes all benchmark arguments explicitly:
  `instrumentation=off`, `parking=off`,
  `notify=always`, selected `counter` and `workload`.
  Both `freshGc` and `recycleTyped` perform identical deterministic
  task IDs, typed/void result checks, GC-visible closure accesses,
  drain and shutdown. The runner validates completed tasks, node
  accounting and workload identity in each child.
- Creates **one fresh child process per case**, alternating policy
  order across rounds/producer counts. The consumer prints its
  own exactly-once correctness and producer-thread CPU/resource
  summary. The driver also obtains **per-child `wait4()`**
  user CPU time, system CPU time, voluntary/involuntary context
  switches, page faults, peak RSS, external wall time and internal
  tasks/sec. Child CPU time covers **all producer and worker
  threads**, unlike the benchmark's producer-only counters.
- Records the exact benchmark-executable SHA-256, Git HEAD, clean
  tracked status, LDC/DUB versions, CPU/governor and
  `perf_event_paranoid`. Snapshots are **not** controlled clocks,
  thermal traces, process pinning or assurances of an idle host.

No additional `@system` D code, synchronization, public API,
task storage policy, notification condition or branch migration was
introduced.

## Optional `perf stat`, permission handling and interpretation

With `--perf-stat=try` (default), an explicit `perf stat`
preflight attempts **task-clock, context-switches, cpu-migrations,
page-faults, cycles, instructions** on `/bin/true`. On
systems where `perf` is absent or the events are refused by
`perf_event_paranoid` or other security policy, it **records
the reason in `environment.txt` and continues the ordinary
`wait4()` matrix**. It will **not** run `sudo`, alter sysctl,
install packages, disable ASLR, lower security settings or modify
governor/affinity. `--perf-stat=require` instead rejects a
missing/refused profiler; use only after verifying the user has
explicitly authorized the environment.

If permitted, it runs **separate** `perf stat`-wrapped process
samples, normally twice for each selected 4/8-producer
GC/recycling × minimal/compute scenario. These are **not**
same-round speed samples and **must never be pooled** with
the plain release throughput rows. Original comma-separated
`perf stat` output is retained in `perf-raw/*.csv` for audit;
`perf.csv` carries best-effort numeric parsing and original
per-child `wait4()` diagnostics. If a counter is marked
`<not supported>` or `<not counted>`, keep it missing,
never impute zero. The user and the reviewer should inspect
event names, multiplexing and scaling metadata before
comparing IPC or cycles/task across host/compiler.

The `--perf-stat=off` mode skips all perf operations, including
permission probing, so the hosted DMD/LDC gate does not depend
on the runner's security configuration.

## Native Dell XPS procedure

From the *actual* existing checkout (previously
`~/Programmiersprachen/dlang/concurrency-d`), preserve untracked
evidence and any local work first:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_native_cpu_profile.py \
  --compiler=ldc2 \
  --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 512 \
  --policies gc recycle --workloads minimal compute \
  --counter=shared --perf-stat=try --perf-repeats=2 \
  --perf-producers 4 8 \
  --output=evidence/r05-xps-native-system

tar -czf r05-xps-native-system.tar.gz \
  -C evidence r05-xps-native-system
```

This generates **60 plain fresh child processes**:
5 rounds × 2 workloads × 3 producer counts × 1 budget ×
2 storage policies = **1,800,000 real completed Tasks**.
If `perf` works, it additionally generates **16
separate `perf stat` samples** (2 repeats × 2 workloads ×
2 producer counts × 2 policies), not counted as plain
throughput replicates. If not, it still produces complete
CPU/context-switch evidence with `perf_available=False`
and the recorded reason. Keep the raw archive and
SHA-256; do not overwrite a previous run's directory
without saving the earlier source-pinned data.

This is the **minimal** versus **compute-1024** mix using the
`shared` execution counter, and budget512 only. Cross-campaign
comparisons with earlier `striped` policy A/B or budget8
storage experiments are **contextual**, not additional iid
samples or direct attribution.

## Files and validation gates

- `raw.csv`: every plain case, internal throughput, external
  wall, total child CPU, producer-only resource counters, process
  context switches, per-process peak RSS, node/result accounting;
- `pairs.csv`, `summary.csv`: matching same-round
  GC/recycle ratios, 30 pairs / 6 groups for the default
  5-round × 2-workload × 3-producer matrix. These rates
  are a storage *control*, not notification-policy A/B;
- `environment.txt`: exact source, executable SHA, compiler and
  kernel/CPU permissions;
- **optional** `perf.csv` and `perf-raw/*.csv`, if events were
  available and permitted.

Hosted quick correctness gate [GitHub Actions (workflow)](https://github.com/alex-1974/concurrency-d/actions/workflows/r05-native-system-profile-smoke.yml)
executes a tiny subset with DMD 2.111 x86-64, LDC 1.41
x86-64 and native ARM64, validating scenario keys, completed
tasks, child and producer resources, and paired CSVs. Hosted
CPU samples **are not** performance qualification.

Use this native data to decide whether a new mechanism
study is justified. A subsequent *single-source,
matched-compiler/config* notification-policy and wake-tail
A/B is appropriate only if whole-system profile evidence
provides a concrete hypothesis not already falsified by
the earlier `waiterAware` study. Do not change
`NotificationPolicy.always`, `freshGc`, inner/outer
lock order, generation predicate or GC-root-before-publication
on a system-wide counter alone.

Research evidence stays on the grandfathered Draft PR #35;
Issue #20 remains open; **do not merge the research branch
wholesale** or write to `develop`/other workspace repos.
