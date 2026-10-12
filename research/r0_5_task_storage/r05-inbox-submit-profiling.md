# R0.5 — Inbox mutex, enqueue and notification profiling

**Status: research-only opt-in probe; correctness/CI PASS on DMD 2.111
x86-64 and LDC 1.41 x86-64 + native ARM64. No native Dell XPS
performance measurements yet.**

Track the grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35),
[Issue #20](https://github.com/alex-1974/concurrency-d/issues/20)
and the immediately preceding [native publication-split review](results/xps-publication-split-review-2026-10-12.md).

## What the prior XPS data supports

In the previous 5-round, 120-process XPS study, the composite
`_pool.trySubmit(node.reference())` segment occupied a median **89.4%**
of the **instrumented** publish bracket. The GC-root append took
roughly 5.9%. The result is *not* proof that the inner mutex,
queue assignment or notification individually is expensive.

**Critical source observation:** the R0.5 `OwnedTaskExecutor` acquires
its outer `_mutex` and keeps it locked across `hasIngressCapacity()`,
`ResultCell`/`TaskHandle` creation, GC-root append and
`_pool.trySubmit()`. Thus different **producers are already serialized**
and cannot *simultaneously* contend on the inner inbox mutex via this
path. The inner `TaskInbox._mutex` is also acquired by workers
performing `takeBatch`, `completeOne`, `wakeGeneration`,
`parkUnlessChanged` and `announceLocalWork`. Any measured wait
can include **worker-vs-producer interference, preemption, GC and OS
scheduling**. It is not a direct measurement of inter-producer
contention on the inner mutex.

## Exact opt-in instrumentation

The new `R05InboxSubmitProbe` version is **compile-time gated** in
`source/concurrency/internal/submission_pool.d`.
It does not exist in the ordinary research/prod build. On the
versioned `TaskInbox.trySubmit` path, without modifying the original
lock order, work-state predicate or notification policy:

| Counter | Meaning |
|---|---|
| `attempts`, `accepted`, `rejectedFull`, `rejectedClosed` | Every call counted while holding the inbox mutex, and its disposition |
| `waitNs`, `maxWaitNs` | Wall-clock interval before `synchronized (_mutex)` through lock acquisition; includes scheduling and instrumentation |
| `holdNs`, `maxHoldNs` | Interval after acquiring the inbox mutex through the lexical scope exit; includes all profiled operations and timer overhead |
| `enqueueCount`, `enqueueNs` | TaskRef slot, used/accepted/generation bookkeeping and any preexisting parking instrumentation; timer is **inside** the mutex |
| `notifyCalls`, `notifySkipped`, `notifyNs`, `maxNotifyNs` | Actual `_changed.notify()` calls and a clock bracket around that method, or skipped notifications under the existing policy; **not worker wake-to-run latency** |

These counters are written **only** under the original inbox mutex.
`TaskInbox.submitStatsAfterJoin` snapshots them under that same mutex.
`SubmissionWorkerPool.inboxSubmitStatsAfterJoin` forwards the
snapshot, and `OwnedTaskExecutor.inboxSubmitStatsAfterJoin` exposes it
under the original outer-then-inner mutex ordering **only after
`closeAndJoin()`**. No profile reads race with running workers.

In this specific benchmark every TaskRef submitted into the inner
inbox is accepted (external admission capacity check remains intact).
For each instrumented child, the runtime and Python driver verify
`attempts=accepted=enqueueCount=tasks`,
`rejectedFull=rejectedClosed=0`, and, under the **unchanged**
`NotificationPolicy.always` setting,
`notifyCalls=tasks`, `notifySkipped=0`. The preexisting tests
also validate all typed/void results, completion, GC-visible captures,
outer admission, root and publish stage counts.

**No semantic change:** No removal/addition of a notification, no
alteration of the worker's generation predicate, no change to
`Condition.wait()` or `notifyAll()`, no batching, queue replacement,
root removal, lock reordering, or policy change. A future
waiter-aware vs always comparison would be a *separate* study.

## Test executables and driver

The new DUB config `task-pipeline-mixed-full-victim-inbox-probe`
combines `R05FullVictimSweep` (full N candidate victim search),
`R05AdmissionStageProbe` (outer admission and composite publish
timing) and `R05InboxSubmitProbe` (inner inbox timing).
The control uses the unchanged
`task-pipeline-mixed-full-victim-sweep` with **no** profiling versions.
Both binaries use the same workload, work ownership, retained roots,
TaskRef dispatch, queue capacity, default `freshGc`/opt-in
`recycleTyped` and `NotificationPolicy.always`.

New independent driver:
`tools/research/r05_inbox_submit_matrix.py`. It runs *fresh Linux
child processes* for each factor combination, switches execution order
across rounds/producer/budget, and emits:

- `raw.csv` — source scenario, throughput, producer-thread GC bytes,
  `wait4` per-process peak RSS and, for `on`, all exact cumulative
  outer/inner timing and counter fields;
- `pairs.csv` — within-round `recycleTyped/freshGc` throughput
  ratios, **separately for uninstrumented `off` and profiled `on`**;
- `diagnostics.csv` — profiled GC **and** recycle cases, per-attempt
  inner mutex wait/hold, per-accepted enqueue and per-notify timings,
  previous composite submission and outer admission timings;
- `summary.csv` — five-round paired medians and direction counts
  for each producer/budget/profile scenario;
- `environment.txt` — precise research HEAD, LDC/DUB version,
  platform, `lscpu`, CPU governor and workload parameters.

**Clock and attribution limitations:** The inner wait/hold periods are
inside the already instrumented outer publish bracket, but the extra
clocks, counters and platform scheduling cause perturbation and
non-additivity. `enqueueNs + notifyNs` is **not** all inbox hold time
and **not** a causal split of the uninstrumented ~2–3 µs. `notifyNs`
measures the call duration at the producer, **not** when or whether an
OS thread wakes or executes. Under `NotificationPolicy.always`,
`_sleepers` is not maintained as a real waiter count; never infer
how many workers were sleeping from this counter.
Do not treat profiled `on` rate compared with `off` rate as an
optimization benchmark or subtract profiler overhead naively.
`GC.allocatedInCurrentThread()` measures only producer-thread
allocations; per-process `wait4.ru_maxrss` may report a floor for
short runs.

## Native Dell XPS protocol

Use the *actual* local checkout path (previously
`~/Programmiersprachen/dlang/concurrency-d`); inspect `git status`
and preserve unrelated tracked/untracked research work before switching.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d

git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_inbox_submit_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budgets 8 512 \
  --workload=minimal --counter=shared \
  --output=evidence/r05-xps-inbox-submit

tar -czf r05-xps-inbox-submit.tar.gz \
  -C evidence r05-xps-inbox-submit
```

Run on AC power without other heavy jobs and preserve original raw data.
The command gives **5 rounds × 3 producer counts × 2 budgets ×
2 policies × 2 modes = 120 independent child processes**,
30,000 tasks each = **3.6 million completed tasks**.
For direct qualitative comparison, use the previous publication split
XPS archive/report, while recognizing that the new profiled code
contains extra timers and the two runs may have different CPU clocks.
Do not join archives as iid runs.

## Checks and next decision

[GitHub Actions run #38255792971](https://github.com/alex-1974/concurrency-d/actions/runs/38255792971)
**PASS** on DMD 2.111 x86-64, LDC 1.41 x86-64 and
LDC 1.41 native ARM64. Hosted smoke checks 384 completed Tasks per
case for `freshGc` and `recycleTyped` with both profiler modes,
admission-stage and inner submission counts, exact notification counts,
separately paired CSVs and no missing scenarios. No hosted speed
threshold is used.

**Decision remains unchanged:** KEEP `freshGc`, DEFER typed recycler
and any change to inbox synchronization. Native measurement must first
show whether the inner inbox time primarily comprises lock-acquisition
wait, queue update, or the `notify()` bracket, and whether its apparent
cost is stable across 1/4/8 producers. If the majority is outside
these brackets, investigate timer gaps and worker scheduling rather
than inventing a mutex replacement. If notification dominates in
the instrumented path, further qualify worker wake behavior before
changing `NotificationPolicy`. Preserving TaskRef lifetime, GC roots,
bounded rejection-before-allocation, shutdown linearizability, and
lost-wakeup prevention takes precedence over an unverified speed gain.

Grandfathered PR #35 remains **Draft**, Issue #20 **OPEN**,
`develop` and all other repositories unchanged. Historical native
XPS archives and reports are not modified.
