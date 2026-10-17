# P42.15 — four-worker idle publication gate

P42.14 found similar median single-worker publish-to-execute latency, with insufficient evidence for a tail-latency benefit. P42.15 adds a **correctness-first** multi-worker test using the exact original and source-derived conditional pool modules.

Each of 12 rounds per shape creates four workers and waits until at least four historical condition-wait entries have been recorded. It then submits **1, 4 or 32** tasks with capacity 64, waits until all have executed, and only then closes the pool to exclude shutdown broadcasts as a means of completing the workload. Both arms validate accepted/completed counts and exactly-once executions. Monotonic timestamps offer a preliminary **maximum submission-start-to-task-start** bound for each burst, reported in ticks.

**Limitations**: four wait entries are not proof that four distinct workers remain asleep; the producer may observe repeated wait calls from one worker. For the 32-task burst, late tasks have a longer publication offset; the maximum is not a pure wakeup or per-task publish latency. Single-task and four-task cases cannot establish how many workers actually woke or executed, and a finite smoke test does not establish starvation freedom or performance. CI debug tests must pass before even the correctness gate is qualified. An optimized, prebuilt XPS multi-worker timing runner and worker identity / confirmed waiter tracking are deliberately deferred until the correctness gate is green.

No public API or production scheduler modification. Original and conditional only differ in the existing research-generated notification overlay.

## P42.16 research refinement: instantaneous waiter enrollment

The conditional research overlay now provides `waiterCount()`, read under the inbox mutex. It increments immediately before `Condition.wait()` and decrements after the call returns while reacquiring that mutex. With four pool workers, a count of four shows **four concurrent wait enrollments** (one per worker), rather than four potentially repeated historical wait entries. The conditional multi-idle consumer requires this new observation before publication. The original production baseline remains uninstrumented and is still gated only by historical `parkCount()`. Thus the two arms have **different pre-publication evidence** and cannot yet support a fair performance comparison, even though both execute the same tasks.

This does not establish that all workers have entered OS kernel sleep or that they stay parked throughout the time between the count observation and submission. The next research step is a **source-derived, similarly instrumented baseline overlay** and worker-specific entry/exit records before any comparative wakeup tail-latency claim. The original production pool and pre-existing P42.14 evidence are not modified.


## P42.16 matched-observation refinement — implementation gate pending

The historical refinement above describes the **initial unequal-arm state**.
The next change uses two disposable, source-pinned research overlays:
`concurrency.research.m1_p42_baseline_pool` and the existing
`concurrency.research.m1_p42_pool`. The baseline continues to execute
**unconditional** `Condition.notify()` for each successful inbox publication;
the conditional arm only notifies on publication when `_waiters != 0`.
Other notification sites (local work announcement, close and final completion)
are unchanged. A generator preflight canonicalizes module names and the
single publication-policy block and asserts **all remaining generated text
matches**. No production source file is modified.

Both overlays count `_waiters` under the original inbox mutex, enroll immediately
before `Condition.wait()`, and leave enrollment after that call reacquires
the mutex. Both also maintain per-worker wait-entry counts and current
enrollment flags under that mutex. Worker IDs are set once at worker-loop
entry and read through a research-only thread-local getter in the callback.
The multi-idle consumer now rejects publication until one coherent mutex
snapshot sees **exactly four simultaneous, distinct worker enrollments** in
both arms. No allocation, snapshot read or output is performed from the
worker's task-execution hot path beyond the per-task record timestamps,
worker-ID store and completion hit. Per-worker wait counters deliberately
instrument the parking path in **both** arms.

For each arm, 12 rounds at each task count 1, 4, and 32 record:

- per-worker historical wait entries and current enrollment before publication;
- one task ID, per-task pre-`trySubmit` timestamp, task-start timestamp and
  executing worker ID for every accepted task;
- exactly-once hits, accepted/completed counts, the distribution of executed
  tasks over four workers, and the burst maximum since its first timestamp;
- completion of every task **before** the close/broadcast, with shutdown and
  native worker joins only after observing all task hits.

`P42_MULTI_IDLE_WAIT`, `P42_MULTI_IDLE_TASK`, `P42_MULTI_IDLE` and
`P42_MULTI_IDLE_PASS` are machine-readable diagnostic lines. This is a
**debug correctness/observability gate**. The additional TLS, per-worker
counters and timestamp writes are not appropriate for an uninstrumented
end-to-end throughput claim. Prior P42.9–P42.14 benchmark baselines still
use the original production module; those measurements must not be compared
as if they had the same instrumentation as P42.16.

### Explicit epistemic limits

Concurrent enrollment in D's condition-variable wait protocol does not prove
four OS threads are already blocked in the kernel at publication. A spurious
wake can change state after the observation; the attempt to submit cannot
atomically freeze all workers. Per-task publish-to-start time includes
admission, lock contention, scheduler delay, and execution start. Burst
maxima additionally include serial publication time. Seeing a task's worker
ID shows actual execution distribution, **not** which other workers woke
and found no work. A 12-round smoke cannot establish fairness, starvation
freedom or stable tail latency. Handle individual rounds as correlated
experiments, not independent data points when interpreting tails.

The research driver generates files only when absent and removes both files
via its exit trap. It does not touch the canonical M0 scheduler, frozen
package surface, PR destination, or prior XPS evidence. DMD 2.111.0 /
LDC 1.41.0 correctness and exact-head CI qualification are required before
a new dedicated, optimized XPS multi-worker raw-data protocol is proposed.
ADR-0001 remains PROPOSED, PR #38 DRAFT, and this is not a merge decision.


### Native XPS diagnostic capture (runner added; results pending)

After the first corrected P42.16 DMD/LDC runtime correctness gate succeeded,
`tools/research/m1_p42_multi_idle_native.sh` and
`tools/research/m1_p42_multi_idle_extract.py` were added for a **later
native XPS run**, not as a claim that such a run has already happened.
The runner uses the two explicit **observed** overlays, not the historical
unobserved P42.9–P42.14 performance variants. The generator's original
two-argument invocation remains the historical byte-for-byte conditional
overlay path (`legacy`); explicit `baseline` and `conditional` select
matched P42.16 instrumentation only.

From the dedicated XPS worktree (do not move or reset the main worktree):

```bash
cd ~/Programmiersprachen/dlang/concurrency-d-p42
git status -sb
git fetch origin
git pull --ff-only origin research/m1-task-lifetime-boundaries
# Pick a NEW, previously nonexistent results directory each time.
bash tools/research/m1_p42_multi_idle_native.sh "$HOME/Downloads/p42-16-xps-01"
tar -C "$HOME/Downloads" -czf "$HOME/Downloads/p42-16-xps-01.tar.gz" p42-16-xps-01
```

**Only run this after an exact-head DMD/LDC green gate.** XPS output is not
available from GitHub-hosted CI. The script refuses existing directories
and overlays, removes its temporary modules on exit, prebuilds both LDC
release binaries, records binary/source hashes plus compiler/CPU/system
and frequency/thermal snapshots, performs warmups, and alternates arms in
three sessions with six paired runs each. Every full run emits 36
four-worker rounds and 444 per-task records; the resulting 36 raw logs
are validated into `tasks.csv` and `rounds.csv` with cardinality and
worker-distribution consistency checks. All raw traces are retained;
no previously recorded evidence is overwritten.

The diagnostic overhead is **intentionally present in both arms**. These
paired comparisons can inform task placement, concurrent wait enrollment,
and task-start observations, but they do **not** isolate a kernel wakeup
cost and are not a replacement for an uninstrumented production-oriented
throughput baseline. `MonoTime.currTime.ticks` values remain raw ticks:
no conversion to nanoseconds without a separately justified clock unit.
Treat rounds within an invocation as correlated, include per-session drift,
and avoid confidence claims from naive per-task P95/P99 independence.
No merge, ADR ratification, or public API promotion follows from this run.
