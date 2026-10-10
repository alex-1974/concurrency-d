# M0 — bounded GC root reclamation after worker dispatch

Status: **implementation candidate** on issue #11/#20; CI and performance qualification pending.
This is a short-lived owned-task follow-up, not a public storage API.

## Problem observed on develop

`OwnedTaskExecutor` strongly retained every accepted `OwnedNode` through
shutdown. With `maxRetained=4096`, even a long-lived executor whose tasks
were all finished could never submit a 4097th job. A result cell being ready
was not a safe node-reclamation signal: the worker might still be accessing
the task record while returning from its execute thunk.

## Implementation decision

Keep the qualified **8-byte `TaskRef`** and `TaskHeader`.
For owned tasks only, the private task record begins with:

```text
CompletionPrefix {
    TaskHeader header;        // existing 8-byte type-erased dispatch
    shared uint returned;     // owned-record-specific marker
}
```

`SubmissionWorkerPool` accepts an optional `afterExecution(TaskRef)`
callback. Its worker invokes the hook **only after** dispatch returns
and pool completion accounting is updated. The owned-task hook atomically
sets `returned = 1` with release ordering. No such hook is installed for
the borrowed/task-probe pool, so the extra branch is absent from its
observable semantics.

`OwnedTaskExecutor` retains pairs of `Object` (strong GC root) and a
pointer to the corresponding marker. When the bounded root budget fills,
its admission mutex protects a compaction pass that examines marker flags
with acquire ordering. Only marked entries can be removed. Vacated D-array
slots are explicitly zeroed to avoid stale GC-visible references in the
backing allocation. The owner never modifies an accepted node while it
is queued or executing.

`trySubmit` returns null on **either** full ingress or fully occupied
in-flight retention budget; `submit` retries outside the admission lock.
A draining/closed executor still throws. At a successful `closeAndJoin`,
all remaining roots are cleared because the worker threads have joined.
An explicit `reclaimCompleted()` enables optional sweeping even without a
new submission. Existing `TaskHandle!R` objects own separate result cells;
dropping a node's GC root must not invalidate a handle or its result.

## Tests and limitations

- Gated running task with retention capacity one remains strongly held,
  and further work is not admitted before post-dispatch completion.
- Subsequent work becomes admissible after the first worker returns.
- Thousands of tasks run with a retention budget of eight across one/four
  workers, including deliberately discarded result handles.
- Shutdown clears all retained roots after join; accepted/completed counts
  remain exactly equal.
- Ordinary external inbox and borrowed task probes use their existing path.

**Not a claim of zero allocation or a production allocator.** Each new
node/result cell is still GC-allocated; the completion hook adds a branch
and an atomic store, and budget-exhaustion compaction is O(budget).
This is a **bounded-lifetime correctness foundation**, not evidence that
the final throughput is competitive with Taskflow/Rayon/oneTBB.
Optimized LDC end-to-end allocation and performance evidence, GC
reachability probes and move-only/complex-capture qualification remain
issue #20/#17.

## Ownership caveat

The caller-side `@system` submission contract for arbitrary closures
is unchanged. Correct storage retention of a closure does not make
captured references to caller stack/local mutable data cross-thread safe.
