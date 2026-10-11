# R0.5 — Conservative waiter-aware notify experiment

**State:** research-only A/B prototype. The production default remains
`NotificationPolicy.always` and `OwnedRecordPolicy.freshGc`. No new
public API, task ownership rules, queue layout, worker search order,
condition predicate or shutdown semantics are promoted.

## Evidence and question

The independently checked native
[Dell XPS useful-wake study](results/xps-wake-outcomes-review-2026-10-11.md)
recorded **44.50% empty first searches after Condition.wait** for the
GC-fresh minimal workload with four producers, and **44.81%** with
eight producers, alongside >2.5 failed steals per task.

**This does not prove excessive `notify` calls are the cause**:
another worker may consume a task before a woken worker searches.
Notification targeting, actual worker sleep, CPU wake time, and
result-handle blocking were not causally attributed.

The first hypothesis is intentionally narrower:

> Can we avoid condition notifications when **no worker is actually
> waiting**, without losing task progress, increasing end-to-end
> latency, or changing the accepted result/shutdown contract?

A second, more aggressive hypothesis (e.g. edge-triggering,
coalescing, spin before sleep, batching) is explicitly **out of scope**.
Skipping notifications while workers *are* waiting or intentionally
delaying a ready task could invalidate forward progress for blocked
or nested tasks; this conservative experiment does not do that.

## Baseline / candidate semantics

The `TaskInbox` tracks a `_sleepers` count, but **only** for the
opt-in `NotificationPolicy.waiterAware` variant.

Under the **same existing inbox mutex**:
- Before entering `Condition.wait`, the candidate increments the
  registered-waiter count.
- `Condition.wait` atomically releases the mutex while sleeping.
- Upon return/reacquisition it decrements the count.
- Any accepted ingress publication **always commits its task,
  accepted obligation and wake generation**.
- The candidate calls `notify` **iff a registered waiter exists**;
  otherwise it skips the call. The baseline always calls `notify`.
- An announcement of newly stealable owner-local work uses the same
  candidate rule; its wake generation still changes.
- `close` and final `completeOne` **always broadcast**.
- The waiting predicate remains the existing generation, nonempty
  ingress or drained state. A future waiter with no prior registered
  waiters must observe the changed generation/ingress and cannot
  incorrectly sleep through a publication.

A registered waiter may have returned from a notification but still
be reacquiring the mutex. It stays registered until it reacquires.
This is conservative, never intentionally withholding a signal
from a registered waiter.

**Metric contract:** legacy `ingressNotifications` counts **accepted
publications**, not actual OS notifications. New metrics explicitly
split actual `ingressNotifyCalls` versus skipped calls, and local
work announcements analogously. Under the profile flag:

```text
ingressNotifications == ingressNotifyCalls + ingressNotifySkipped
localNotifications   == localNotifyCalls + localNotifySkipped
```

The baseline must report **zero skipped notifications**.

## Validation plan and limitations

1. **Unit-test safety:** publication before sleep (generation
   protects lost wake), publication while a real waiter exists,
   concurrent producers/exactly-one execution, no-work shutdown, and
   typed-result success.
2. **Compiler and native platform:** DMD 2.111.0 and LDC 1.41.0
   x86-64, plus native ARM64 LDC; all semantic tests and the optimized
   end-to-end benchmark must pass.
3. **Uninstrumented A/B throughput:** a fresh child per case,
   round-paired `always` vs `waiter` with alternating order. Both
   run all identical tasks, result observations, GC handling and
   shutdown. No per-event counters on the throughput path.
4. **Separate observed A/B:** with parking profiling enabled, count
   actual and skipped notifications, per-task condition waits, useful
   and empty first searches. **Do not** equate profile-ON and OFF
   throughput or interpret a lower `notify` count as fewer useful
   wakeups without actual scheduling evidence.
5. **Idle CPU & low-rate wake latency:** a separate executable
   creates the worker pool, samples `getrusage(RUSAGE_SELF)` CPU
   during an empty idle interval, then measures repeated
   submit-to-typed-result times across 1ms interarrival gaps;
   reports nearest-rank p50/p95/p99 and max. This is **not**
   high-throughput latency or a real-time deadline guarantee.
6. **Fairness and blocking:** the present work uses exact completion
   and deliberately isolated work. Before any production promotion
   add per-worker dispatch distribution, adversarial nested/blocking
   task cases, low-load responsiveness, and long-idle/no-work CPU
   on the target workstation. Merely passing the A/B matrix does not
   satisfy this promotion gate.

**Important caveat:** the candidate still sends one notification per
accepted publication whenever waiters exist. It therefore cannot
directly remove all the previously observed empty post-wait searches.
A throughput increase in hosted CI may arise from fewer wasted
`notify` calls or differences in scheduling noise, and cannot be
assumed to be a solution to the prior 45% symptom.

## Native Dell XPS reproduction

From the repo's **existing local checkout**:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only

# Fair paired process throughput and notification-decision counts:
python3 tools/research/r05_notification_policy_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budget=512 \
  --policies gc recycle --workloads minimal compute \
  --output=evidence/r05-xps-notification-ab

# Empty idle CPU and low-arrival-rate submit-to-result p50/p95/p99:
python3 tools/research/r05_notification_idle_latency.py \
  --compiler=ldc2 --workers=4 --idle-ms=250 \
  --samples=256 --gap-ms=1 --rounds=5 \
  --output=evidence/r05-xps-notification-idle
```

Each script writes `raw.csv`, `summary.csv` and
`environment.txt` (source SHA, compiler, CPU topology, governor).
Keep the original files, warm-up/foreground load and temperature/
power notes. Compare paired runs within the **same source SHA**.
A CPU0 `powersave` governor observation does not establish constant
frequency or stable thermal behavior.

## Research decision gate

**KEEP** the original always-notify production baseline. **DEFER**
`waiterAware` promotion until controlled native results demonstrate
a repeatable benefit *without regression* in p95/p99, idle CPU,
fairness, shutdown/lost-wakeup, result ownership, or GC correctness.
No per-platform performance threshold is imposed on noisy hosted CI.

If the conservative variant is neutral, retain it as evidence and
**do not leap directly** to a lock-free or spin-based redesign.
