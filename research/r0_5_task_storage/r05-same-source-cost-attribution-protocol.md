# R0.5 — Same-source admission, worker-resource and acquisition-count diagnostic

**Research-only, no scheduler algorithm change.** As of 2026-10-13,
the [native XPS acquisition-pressure report](results/xps-work-acquisition-efficiency-review-2026-10-13.md)
and [repeated victim scan audit](results/xps-victim-repeat-trace-audit-review-2026-10-13.md)
have established frequent unsuccessful steal probes, actual waits and
a recurring search-order pattern. They do **not** determine their
incremental CPU cost or license skipping any foreign deque.

## Evidence gap identified by source audit

Before this experiment, native profiling was **not a comparable,
additive cost decomposition**:

- `r05-xps-inbox-submit.tar.gz` measured
  `24d613a8d261bbb636052f0e3df728fbb0b77f68` and contains
  **producer-side elapsed wall-time intervals** around outer admission,
  publication, an inner inbox lock and `notify()`. The stopwatch
  samples include scheduling delays and profiler overhead.
- `r05-xps-worker-parking-correlation.tar.gz` measured
  `1f97cf5616c67b670d2b601ba4a716822d197bd5` and contains
  **Linux per-worker and per-producer CPU** and **event counts** of
  waits, steals and empty searches. It has **no measured CPU duration
  per steal or wait**.
- Both were LDC 1.41 XPS campaigns with four workers, but the
  measured source revisions, executable hashes, instrumentation and
  sometimes workload configuration differ. **No subtraction or
  addition of their means can yield a causal Task latency budget**.
  E.g. a 40µs outer mutex *wait per attempt* may include a descheduled
  producer and is not 40µs of CPU use per completed Task; producer
  waits can overlap other threads' work.

Further iterations must **not** claim that admission, stealing and
parking cost independent disjoint percentages of total time.
The outer producer mutex synchronizes entry into the inner inbox
submission; the worker inbox mutex interacts with it indirectly.
Root publication, task execution, worker parking and GC may
interleave in time.

## Smallest new joint experiment

Only a new DUB **research configuration**, Python orchestrator and
CI smoke were added. No D submit implementation, queue implementation,
TaskRef lifetime or wake-predicate code is modified.

- Existing `task-pipeline-mixed-full-victim-sweep` (plain)
  remains an uninstrumented release control, **no admission timers**,
  **no worker resources**, parking profile OFF.
- Existing `task-pipeline-mixed-full-victim-worker-resource`
  (worker) samples Linux `RUSAGE_THREAD` **at worker start/end**,
  turns on the existing runtime parking/wake/steal counters, but
  leaves producer admission probes OFF.
- New `task-pipeline-mixed-full-victim-joint-cost` DUB config
  compiles `R05FullVictimSweep` +
  `R05AdmissionStageProbe` +
  `R05WorkerThreadResources`.
  It **deliberately does not compile `R05InboxSubmitProbe`**,
  whose per-submission inner mutex clocks are active even when
  external `instrumentation=off`, invalidating a low-impact control.
  The original inbox/notification micro-timings remain *historic
  contextual evidence only*.
- **joint_off:** the new joint executable, `parking=on`,
  `instrumentation=off`. Existing worker and parking counters
  are present, but admission observed-submit timing is OFF.
- **joint_on:** the **EXACT SAME compiled joint executable SHA**,
  `parking=on`, `instrumentation=on`. This invokes existing
  `submitObserved`/AdmissionProbe stage clocks and histogram
  updates, with worker CPU and worker acquisition counts measured
  simultaneously. All other runtime parameters are the same.
- The `plain` and `worker` controls are **separately compiled
  executables**. `worker/plain`, `joint_off/worker` and
  `joint_on/joint_off` rate ratios are **probe-perturbation
  diagnostics**, never statements of algorithmic performance gain.

For each child, verify all accepted/completed, 1,765 observed typed
handles per 30k Task sample, full root/node accounting, deterministic
minimal/compute result checksum, close/join, and no missing worker
resource slots. Under runtime parking, check wait return-state
partition, first-search outcomes, exact claimed/executed counts,
steal-success <= attempts, exactly one always-policy ingress notify
per accepted Task and no skipped notification.

For joint_on also require admission:
`attempts=accepted+retentionFull+ingressFull`,
`accepted=tasks`,
`gateCount=attempts`,
and `cellCount=nodeCount=publishCount=rootAppendCount=
inboxSubmitCount=tasks`.
`rootAppendNs<=publishNs` and `inboxSubmitNs<=publishNs`
are nested bracket consistency checks, **not** a requirement that
the corresponding times add exactly to a total.

**Collected per actual 30k-Task child:**
- Producer outer admission mutex elapsed `wait_ns/attempt`,
  `hold_ns/attempt`, publication stage elapsed means
  (gate, cell, node, root append, composite inbox submit);
- Worker and producer **CPU microseconds** via thread boundary
  RUSAGE_THREAD, plus whole-process wait4 CPU;
- Worker voluntary/involuntary switches and producer equivalents;
- worker empty local-pop, empty inbox claim, failed/successful
  steal attempts, condition waits, empty first search after wake
  and inbox Tasks/claimed batch per **completed Task**;
- Per-factor paired runtime probe rate ratios and source/build
  SHA hashes.

No worker `steal()` nanosecond measurement is added. Its per-event
CPU cost **remains unknown**: dividing total worker CPU by failed-steal
count would be invalid since workers also execute Tasks and perform
other work.

## Native XPS reproduction

From the existing checkout, after preserving tracked/untracked work:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_joint_cost_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budget=512 \
  --policies gc --workloads minimal compute \
  --counter=shared --cooldown-ms=50 \
  --output=evidence/r05-xps-joint-cost

tar -czf r05-xps-joint-cost.tar.gz -C evidence r05-xps-joint-cost
```

The default study executes **5 rounds × 2 workloads × 3
producer counts × 1 storage policy × 4 diagnostic modes =
120 fresh child processes** and **3.6 million completed Tasks**.
Exactly **30 joint_on admission stage cases**, **90 profiled-worker
children × 4 = 360 worker resource rows**, **30 within-round
four-mode pairs**, **six median scenario summaries**. The original
XPS GC/recycling A/B already failed to establish a general recycler
gain; GC-only keeps this study narrow.

Expected evidence files:
`raw.csv`, `worker.csv`, `stages.csv`, `pairs.csv`,
`summary.csv`, `environment.txt`.
All cases preserve the `always` notification policy, the
full victim coverage, bounded ingress, GC-root-before-publication
and the exact workload; `shared` is explicitly pinned.
A second experiment with `striped` is **not** needed unless a
new counter-mode confounder emerges.

No privileged Linux `perf`, affinity or governor change is requested.
The Dell XPS prior `perf` preflight failed under
`perf_event_paranoid=4`. This host may show CPU clock,
thermal and background load drift; never infer an exact bound or
speedup from its instantaneous governor/frequency snapshot.

## Decision gate

Analyze **per child, then per-round**, keeping workload and producer
count separate. Determine whether higher concurrency correlates
with simultaneous increases in outer admission wait, producer and
worker CPU and active search/parking counts **in the same
instrumented case**, and quantify the probe effect using the
same-binary `joint_on/joint_off` pair.

The experiment may identify **where to put a future controlled
intervention**. It does not itself supply a causal breakdown of
CPU cost or prove that a mutex-free strategy, spinning, delayed
publication, skipped queue probes or notification coalescing will
be equally correct/faster. A new algorithm needs a separate matched
**uninstrumented** throughput, closure/GC-root/lifetime, idle wake
tail and full-victim coverage test; keep a blocked-worker progress
control. `freshGc` and `NotificationPolicy.always` remain
the selected defaults; `recycleTyped` experimental.

Research evidence remains on grandfathered Draft PR #35;
Issue #20 stays open; **do not merge this branch wholesale** or
write `develop` / another workspace repository.
