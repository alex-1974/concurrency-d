# M0 executor lifecycle — concurrent draining shutdown

Status: internal production candidate; public API and task reclamation
remain separate work. Tracking: [issue #12](https://github.com/alex-1974/concurrency-d/issues/12).

## Decision

The **owned** executor serializes submission admission and shutdown under
one `Mutex`, with an accompanying `Condition` for waiting controller
threads. The lifecycle has three states:

```text
RUNNING -- first closeAndJoin --> DRAINING -- joined workers --> STOPPED
   |
   +-- successfully admitted task --> completion obligation
```

The transition to DRAINING is the admission **linearization point**.

- A task accepted under the admission mutex before this transition must
  execute and publish its result or caught exception.
- A task whose attempt observes DRAINING/STOPPED is rejected; no task
  completion obligation is created for that attempt.
- Full ingress is a transient non-admission: the optional producer retry
  occurs outside the admission mutex and can subsequently observe close.
- Shutdown **drains**, not cancels, all accepted tasks.
- Exactly one external controller thread performs the blocking join.
  Concurrent or repeated callers wait for STOPPED on the condition and
  receive the same shutdown result (if joining itself fails).
- The executor retains owned task nodes until join finishes. Separate
  `TaskHandle!R` result cells remain usable after shutdown and dropping
  a handle never cancels accepted work.

## Memory and threading boundaries

The scheduler owns its local deques and parking protocol. Task node
dispatch and result publication happen before the worker completion count
increments. A result `get()` waits on its private condition variable and
may return before the whole executor is shut down.

`closeAndJoin` **must not be called from a task running in the same
executor**: a worker cannot join itself. The current internal prototype
also does not support destroying the executor while other methods or
worker threads still use it. These restrictions are explicit and are
not concealed by an `@safe` public API promise.

The header remains 8 bytes and the borrowed task handles remain
non-owning. No more mutex traffic is added to the normal worker-local
queue path by this control-plane lifecycle change.

## Regression coverage

- shutdown with an in-flight task blocked on an atomic test gate;
- queued success and queued exception before the close transition;
- three simultaneous controller callers to `closeAndJoin`;
- admission rejection immediately after DRAINING;
- completion/result observation after STOPPED and idempotent rejoin;
- concurrent competing producers versus close, with accepted/completed
  accounting exactly equal to the successful submissions.

## Follow-up work

- Worker creation failure injection, cleanup and whole-pool failure
  propagation from issue #12;
- no worker may call blocking `get` on an unmet result in a one-worker
  executor without a helping/wait strategy (document/specialize before
  public release);
- full task-owned callable lifetime, safe cross-thread capture limits,
  and supported move-only results (#11/#17);
- resource reclamation without retaining every completed node until
  executor shutdown (#20).

This is a pragmatic internal lifecycle contract, not a lock-free or
formal-verification exercise.
