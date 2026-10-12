# R0.5 — Existing worker parking/wakeup/steal counters versus worker CPU/switches

**Status:** research-only, source audit + new paired protocol; no TaskRef, queue,
lock, GC root, wake generation, parking algorithm or notification change.
Uninstrumented GC/default and `NotificationPolicy.always` remain KEEP;
recycler and architectural optimization promotion DEFER. Prior native
XPS results preserved on the grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
and [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
The newer study has **no native Dell XPS results yet**.

## Source audit: counters already present, no need to invent another tracer

The research implementation at `perf/r05-owned-task-pipeline` already has
a runtime `parkingProfile` switch in
`source/concurrency/internal/submission_pool.d`.
With parking profiling **off**, no parking counter is read or written.
With it **on**, worker-owned ordinary integer counters are updated
under the worker's existing execution flow and copied into private
worker slots only after the loop finishes. Inbox counters remain under
the **original inbox mutex**, with no separate instrumentation lock.

| Existing field(s) | What is counted | What is **not** established |
|---|---|---|
| `conditionWaits`, `waitReturns` | Actual calls to and returns from `Condition.wait()`; equality required after join | Number of voluntary OS switches, notification attribution, sleep duration |
| `waitReturnsStillBlocked` | Returned to a predicate which still prevents progress; retried | Proof of a spurious OS wake |
| `waitExitsInboxPending`, `waitExitsGenerationOnly`, `waitExitsDrained` | Mutually exclusive final wait-loop exit predicates | Which notify originated it |
| `wokeToLocal/Inbox/Steal/EmptySearch/Drained` | First search outcome after a final wait-loop exit | Worker wake-to-task latency, useful causal notification fraction |
| `stealAttempts`, `stealSuccesses` | Actual local scheduler steals and successes; failures = attempts − successes | CPU nanoseconds wasted by a failed steal |
| `claimedTasks`, `claimedBatches` | Inbox batch sizes after successful claims | Why upstream publication timing produced that occupancy |
| `ingressNotifications`, `ingressNotifyCalls/Skipped` | Publication count and conditional `notify` call decision | Number of sleeping workers (baseline always does not track `_sleepers`) |
| `parkChecks`, `skippedParks`, `localMisses`, `ingressMisses` | Worker attempts to find work and decide whether to park | Reason for an individual process context switch |

All `parking`, `wakeup` and `notification` rows already exist in
`benchmarks/task_pipeline/multi_producer.d` when the runtime switch
is `on`. They are checked against Task execution, wait-return and
first-following-search conservation conditions.

**Conservation conditions for an accepted fully drained run:**

```text
conditionWaits == waitReturns

waitReturns == waitReturnsStillBlocked
  + waitExitsInboxPending + waitExitsGenerationOnly + waitExitsDrained

waitExitsInboxPending + waitExitsGenerationOnly + waitExitsDrained
  == wokeToLocal + wokeToInbox + wokeToSteal
   + wokeToEmptySearch + wokeToDrained

stealSuccesses <= stealAttempts
claimedTasks == executions == ingressNotifications == acceptedTasks
ingressNotifyCalls + ingressNotifySkipped == ingressNotifications
localNotifyCalls + localNotifySkipped == localNotifications
```

In current `NotificationPolicy.always`, `ingressNotifySkipped==0`
and every admitted Task triggers an ingress `notify` call.
**Important:** The worker's actual parking mutex predicate continues
to depend on its generation and work state, not on notifications as
durable tokens. We must not alter that protocol to reduce counts.

## Historic native evidence that motivates same-source correlation

The [native XPS wake outcome study, 2026-10-11](results/xps-wake-outcomes-review-2026-10-11.md)
under an **earlier source revision**, 4 workers, striped benchmark counter,
retention budget512, 5 rounds, 30k Tasks per process found:
- fresh GC / minimal / 4p: median **0.8558 condition waits/Task**,
  **2.5153 failed steals/Task**, **44.50% empty first post-wait searches**,
  **55.48% useful first searches**, **1.569 claimed Tasks/batch**;
- fresh GC / compute-1024 / 4p: **0.6206 condition waits/Task**,
  **1.8257 failed steals/Task**, **35.63% empty**, **64.35% useful**,
  **1.470 Tasks/batch**;
- in that earlier corpus, all 60 instrumented cases had
  `waitReturnsStillBlocked=0`, showing an immediate re-wait loop is
  **not supported as the dominant churn mechanism** in those runs.
  This observation is not a universal spurious-wake guarantee.

The [newer XPS worker resource study, 2026-10-12](results/xps-worker-resources-review-2026-10-12.md)
used a **different source HEAD**, four workers, shared counter and
worker start/exit `getrusage(RUSAGE_THREAD)`. At compute-1024,
1→8 producers raised worker CPU by ~208 ms and producer CPU by
~202 ms per 30k Tasks, and raised worker voluntary switches by
~21,666 and producer switches by ~19,840 in matched groups.
Those CPU/switch and older wake counts **cannot be joined row-wise
or cited as direct same-source correlation**.

The [shared-vs-striped counter native A/B](results/xps-counter-contention-review-2026-10-12.md)
found no general scaling cure from producer-indexed stripes, so
this phase defaults to `counter=shared` to match the later
worker-resource campaign; the older striped wake results remain
context only. The earlier [waiter-aware A/B](results/xps-notification-ab-review-2026-10-11.md)
was inconclusive or negative for net performance; that policy
is **not** being retested or promoted here.

## New three-mode native protocol, same source and correlated worker data

**New Python driver:** `tools/research/r05_worker_parking_correlation.py`.
It imports the already-qualified CSV schemas from
`r05_worker_parking_matrix.py` and
`r05_worker_resource_matrix.py`, uses their existing **unchanged
D executable code** and parses the original benchmark output.
No D implementation/benchmark edits were necessary.

Use **two** optimised release executables:
1. **plain** — existing `task-pipeline-mixed-full-victim-sweep`
   (`R05FullVictimSweep` only), `parking=off`; plain authoritative
   throughput/background context and whole-child/producer resources.
2. **worker** — existing `task-pipeline-mixed-full-victim-worker-resource`
   (`R05FullVictimSweep`, `R05WorkerThreadResources`),
   `parking=off`. Four worker start/stop CPU/switch snapshots and
   original producer/process resources, without parking event writes.
3. **combined** — the **exact same binary hash** as `worker`
   with `parking=on`: all four worker-resource snapshots **plus**
   preexisting `parking`, `wakeup`, `notification` counters.

Only the **third** mode updates event counts in the worker/inbox
paths; they are ordinary counters and can change scheduling/codegen.
All three retain `instrumentation=off`, full foreign-victim scan,
4 workers, 64-slot ingress, `NotificationPolicy.always`, identical
typed/void/GC-visible tasks, TaskHandle checks, close/drain semantics,
and unchanged `freshGc`/`recycleTyped` policies.
Alternate mode ordering by round/producer/policy; the separately
compiled plain baseline is **not a codegen-identical version** of
worker/combined. Compare `combined/worker` throughput to estimate
observer effects, **not to estimate a hypothetical optimisation**.
These are *short mixed-task workloads* with start/close overhead.

All output is created by fresh Linux child processes and includes:
- `raw.csv` — process total and producer/worker CPU and context switches,
  existing counts, useful/empty post-wait search fractions, failed-steal
  and batch diagnostics, binary hashes, exact task/result checks;
- `worker.csv` — each indexed worker's OS-thread CPU and context-switch
  totals for worker and combined runs;
- `pairs.csv` — same-round mode comparisons for throughput and worker/
  producer voluntary-switch/CPU values (never an algorithm speedup);
- `summary.csv` — within-run per-task park/failed-steal statistics,
  first-search outcomes, and worker vs producer resources;
- `environment.txt` — exact research HEAD, both executable SHA-256s,
  LDC and DUB versions, snapshot governor/CPU, mode and protocol warnings.

If no final wait-loop exit was observed in a short scenario, the
useful/empty search ratio is preserved as **missing (blank)** rather
than represented as 0%. This is distinct from an observed 0% rate.

**Expected default matrix:** 5 rounds × 2 workloads × 3 producer counts
(1/4/8) × 2 record policies × **3** modes = **180 independent fresh
processes, 30,000 completed Tasks/process = 5.4 million Tasks**.
`raw.csv` **180** rows; `worker.csv` **480** rows from 120
worker-resource-mode processes ×4 workers; `pairs.csv` **60**
same-round triplets; `summary.csv` **12** factor groups.
No additional per-task clock, perf call or kernel tracing required.
On XPS, `perf` previously failed under `perf_event_paranoid=4`;
this protocol does not request privilege changes.

### Dell XPS command

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_worker_parking_correlation.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budget=512 \
  --policies gc recycle --workloads minimal compute \
  --counter=shared --cooldown-ms=50 \
  --output=evidence/r05-xps-worker-parking-correlation

tar -czf r05-xps-worker-parking-correlation.tar.gz \
  -C evidence r05-xps-worker-parking-correlation
```

Review original evidence archive bytewise and source-pin it before
accepting any result. The Dell i7-9750H `powersave` governor and
point-in-time CPU-frequency snapshot do not establish workload clocks
or thermals. Keep earlier 2026-10-11 and 2026-10-12 studies unmodified.

### Decision boundaries

The most useful next answer is **whether rises in worker voluntary
switches alongside producer concurrency track increases in actual
condition-wait entries and empty first searches, or instead vary
independently**. Correlation is descriptive, not causal; for example
`Condition.wait()` may produce OS scheduling events but is not
one-to-one with the reported count.

A large rise in failed steals/Task with comparatively stable
actual waits would implicate active fruitless searching as a
**hypothesis**, not a measured CPU attribution. Conversely,
many empty post-wait first searches may motivate a *new* controlled
wake-work acquisition mechanism study, but require a separate
same-source uninstrumented policy A/B and low-arrival tail-latency
regressions before changing wake semantics. If both worker and
producer costs remain high, do not redesign just one side.

**Until then KEEP:** existing TaskRef lifetime, GC strong-root
registration before publication, bounded rejection before allocation,
close/join linearizability, generation-predicate wake safety,
`freshGc` and `NotificationPolicy.always`. **DEFER:**
typed recycler promotion, notification suppression, lock-free inbox,
admission restructuring and a worker spin policy. Research history
stays on grandfathered Draft PR #35; `develop`, `main` and
other workspace repositories are not written.
