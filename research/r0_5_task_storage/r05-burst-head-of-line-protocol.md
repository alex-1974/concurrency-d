# R0.5 — Bounded burst head-of-line placement experiment

**State:** research-only diagnostic on the grandfathered
`perf/r05-owned-task-pipeline` branch (Draft PR #35).
The scheduler, `TaskHandle` public semantics, generation-based
parking, worker-count policy, GC-retention rules and `develop`
are **unchanged**.

## Motivating observation

The first semaphore saturation smoke admitted four blockers as a burst
but did not reliably observe all four starting. A worker may claim
several ingress records in one batch, execute its first and block,
leaving additional accepted records in its owner deque. A separate
sequential-start test proved normal fixed-worker capacity semantics
but did not quantify the original burst behavior.

**Hypotheses, not assumptions:**

1. At the end of a short fixed observation window, some blockers
   may be **accepted but not yet started**, even when not all executor
   workers have entered the blocking semaphore.
2. A worker may have claimed multiple ingress records and
   parked in the first task; other workers may **steal** subsequent
   tasks or may be busy elsewhere. The claim and execution owner
   need not be identical.
3. The placement effect may vary with notification policy,
   record retention policy, worker count, and task-arrival burst.
   A single small hosted CI sample cannot qualify throughput,
   task starvation, fairness or tail latency.

## Implementation

`benchmarks/task_pipeline/burst_head_of_line.d` publishes
`blockers` typed tasks in rapid succession, followed by
`siblings` runnable typed tasks, without acknowledging
individual blocker startup. A shared `Semaphore(0)` holds
every started blocker. The controller sleeps for a fixed
`probe_ms` using `Thread.sleep` (it does **not** busy-yield),
then takes release/acquire snapshots of:

- **Per-task blocker and runnable sibling:** unique task ID,
  whether its callable began before semaphore release,
  **executing worker index**, resolved by matching
  `Thread.getThis().id` with that worker's after-join
  profile slot, and relative start delay from the beginning
  of the burst.
- **Per-worker:** ingress batches/tasks claimed, tasks executed
  directly from ingress, executed from own local deque,
  successfully stolen tasks executed, and total executions.
- **Aggregate:** pre-release started blockers, runnable
  siblings completed, distinct execution worker count,
  post-join total claimed/executed and stolen work.
  A separate `siblings_after_all_starts` diagnostic counts
  siblings whose callable started after the last blocker
  recorded startup **and before release**, only when every
  blocker had started by the snapshot. Siblings completed
  earlier are not evidence of progress by already-saturated
  workers. The blocker start record precedes its call to
  `Semaphore.wait()`, so this timestamp is an approximation
  to blocking entry, not a kernel-observed sleep transition.

Task-to-executing-worker mapping is **exact for an observed
execution**, but per-worker `ingressClaimedTasks` is only an
**aggregate claim count**. It does **not** identify which
specific blocker was first claimed by which worker. Likewise,
a successful steal counter does not identify the victim deque
or the stolen task ID. Do not infer task-specific claim/steal
causality from correlated counts.

The worker-source counters and OS thread identity are
**opt-in** additions to `WorkerParkingStats`, written by
one worker into its own slot and read only after successful
`closeAndJoin`. The OS thread IDs are mapped to stable
0-based pool worker slots in the ephemeral D process.
The runner archives slot indices, **not raw OS thread IDs**.
The default non-profiled code path does not allocate additional
counter storage or use additional atomics/timestamps.

After observation the controller posts **one semaphore token
for each accepted blocker**, including those not yet started,
then joins the pool. All task handles are observed. The D
executable rejects an incomplete accepted/completed count,
a duplicate task execution, an unknown worker identity,
lost claim accounting, and inconsistent execution source sums.
The parent Python harness imposes a **15-second subprocess
deadline** so a true hang is reported rather than lingering.
A timeout is a **failed experiment**, not suppressed evidence.

## Two distinct questions

- **Burst all-blocked scenario:** four blockers / four workers.
  If all four start before gate release, no worker remains
  available for runnable siblings; this is expected fixed
  pool saturation. If fewer than four start, the observation
  describes delayed admission-to-start and competing work
  placement, *not necessarily* lost work.
- **Partial-block scenario:** three blockers / four workers.
  This probes whether the fourth worker can execute runnable
  siblings even if some blocker tasks remain pending in deques.

Neither scenario should impose a fixed minimum number of
pre-release starts or steals. **All accepted tasks must
nevertheless finish after external release**, with exact
typed results, close/join and task-ownership correctness.

## Data handling and interpretation

The process-isolated Python driver
`tools/research/r05_burst_head_of_line.py` alternates
`always` and `waiter` run order and exercises both GC-fresh
and recycling under otherwise matching parameters.

It writes:

- `raw.csv` — one complete burst record per child;
- `claims.csv` — complete per-worker aggregate claim/execution
  source metrics;
- `tasks.csv` — blocker-to-worker execution mapping,
  before-release flag, relative startup timestamp;
- `siblings.csv` — runnable sibling ID, executing worker,
  before-release flag, and relative startup timestamp;
- `summary.csv` — group medians and number of fully started runs;
- `environment.txt` — Git SHA, compiler, CPU topology, parameters.

Measured start delay is **task publication window -> task callable
entry**, not queue residency time, OS notify-to-run latency, or
a generalized p99 scheduling latency. Both blocker and runnable sibling callables have
per-task start timestamps. The Python process wall time includes
startup, blocking delay, release, shutdown and file output; it
is not a throughput benchmark.

### Dell XPS reproduction

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only

python3 tools/research/r05_burst_head_of_line.py \
  --compiler=ldc2 --workers=4 --blockers 3 4 \
  --siblings=8 --probe-ms=100 --rounds=5 \
  --policies gc recycle \
  --output=evidence/r05-xps-burst-head-of-line
```

The CI subset runs LDC 1.41 on native x86-64/ARM64 with
two rounds, a shorter observation window, and both policies.
The consumer gate also compiles and runs the D executable
under DMD 2.111 and LDC 1.41 (native x86-64 and ARM64).
There is no timing or fairness percentage **CI gate**.

## Decision requirements

**KEEP** the current accepted freshGC/always-notify
generation-safe baseline. **DEFER** changing deque batch size,
work-stealing victim order, progress semantics, thread count,
worker blocking strategy or user-visible TaskHandle guarantees.

The next step after completing an actual five-round Dell-XPS
matrix is to inspect task-specific delays and worker claim
concentration. If a reproducible harmful queue-residency
mechanism emerges, isolate **one** conditional scheduling
candidate with bounded latency, fairness, idle CPU, ownership,
lost-wakeup, close/join and DMD/LDC correctness gates.
Do not promote a speculative optimization merely because
more tasks were started at the fixed snapshot boundary.
