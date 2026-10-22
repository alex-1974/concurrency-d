# Public CPU executor — version-zero API candidate

This candidate exports a small API through `import concurrency`. It is not a
published/stable release. It builds on the separately reviewed M0 lifecycle
boundary; the public release gate, license and package publication remain open.

## Quick start

```d
import concurrency : Executor;
import std.stdio : writeln;

int answer() { return 42; }

void main()
{
    auto executor = new Executor(2, 32, 64);
    scope(exit) executor.closeAndJoin();
    auto result = executor.submit(&answer);
    writeln(result.get());
}
```

Run the checked-in independent CPU/completion example from the repository root:

```sh
dub run --root=examples/cpu-executor --compiler=dmd
dub run --root=examples/cpu-executor --compiler=ldc2 --build=release
```

The example imports only the public module. Workers compute 48 chunks; the
consumer polls readiness and applies results only on its controlling thread.
This is an event-loop-style handoff example, not a GUI adapter or latency claim.

## Surface

| Symbol | Behavior |
|---|---|
| `Executor(workers, ingressCapacity, maxRetained = 4096)` | Explicit positive limits; setup completes before native worker startup |
| `executor.trySubmit(callable)` | One attempt: typed handle on success, null on bounded capacity, ExecutorClosedException after close |
| `executor.submit(callable)` | Retry capacity rejection until admitted or closed; may wait indefinitely |
| `executor.closeAndJoin()` | Stop admission, drain, join; repeated/concurrent external calls coordinate |
| `TaskHandle!R.isComplete()` | Synchronized result/error readiness; not last worker access |
| `TaskHandle!R.get()` | Wait, return a copy of R (or void), or rethrow the stored task failure; repeatable |
| `ExecutorClosedException` | Submission observed draining/joined executor |
| `WorkerSelfJoinException` | Same-pool worker tried to close its executor; rejected before lifecycle state changes |

No raw TaskRef, ResultCell construction, queue, registry or diagnostic counters
are exported. Handles are created only by accepted executor submission.

## Ownership, captures and supported values

Submission is explicitly **@system**. F must be callable without arguments and
support the default storage, copy construction and assignment used by the node.
A non-void R must support the corresponding result-cell operations. Unsupported
move-only/nonassignable values are rejected at the facade's `supportedTask`
constraint. This is an implementation/representation constraint, not a universal
D ownership trait or a proof of safe copying/capturing.

Struct callables, function pointers and delegates are supported when they meet
those requirements. Callables must be valid (including non-null function/delegate
and referenced objects). User copies/destructors must not reenter executor
operations while admission is locked or invalidate published data.

The executor retains accepted GC-backed task records and their reachable GC
graphs. A copied pointer, delegate, slice or class reference is **not** a deep copy
or a race-freedom guarantee. Keep all external/borrowed referents alive until
successful closeAndJoin and synchronize shared mutable state yourself. No general
@safe capture contract or TaskScope is claimed.

Keep the executor itself explicitly rooted through closeAndJoin. A handle owns
its result/error cell independently of the task record, but does not substitute
for executor ownership. Dropping a handle does not cancel accepted work. Record
reclamation uses the existing post-dispatch release/acquire marker; `get` or
`isComplete` alone does not certify that the worker has stopped using the record.
Results remain available after reclamation and successful executor shutdown.

`get` returns by value, but copying a mutable reference result still returns a
reference to the same graph; subsequent cross-thread use needs synchronization.
No deterministic GC destruction timing or destructor-based join is promised.

## Capacity and progress

The inbox limit bounds currently queued external entries. The retained limit
bounds record count, not heap bytes, handle count or total tasks over the
executor's life. The two distinct limits can both cause trySubmit to return null.
Known rejection occurs before allocating the task's node/result graph; arbitrary
user callable-copy operations may themselves allocate or throw.

The executor reclaims returned records as its bounded retention budget fills.
An application does not need a public sweep call to keep submitting work. A
result may become ready just before its record becomes reclaimable, so an
immediate trySubmit may still return null. submit retries that boundary.

There is no deadline, fairness, starvation-freedom, worker compensation or nested
join-helping guarantee. A worker must not block on an unmet task that requires
capacity from its exhausted pool, or retry admission forever when its own task
prevents capacity from being released. Cross-pool dependency cycles can also
deadlock; allowed foreign-pool close is not a general cycle detector.

## Failures and shutdown

Ordinary task Exceptions are stored in their own handles and rethrown by get;
other accepted tasks continue. Shutdown drains and does not aggregate/rethrow all
task errors. Dropping a failed task's handle may leave its error unobserved.
The existing owned thunk also records a deliberately thrown Error, but this is
not a guarantee of recovery from arbitrary Error, memory corruption, OOM or
native synchronization failure. If publishing a task failure itself fails, the
worker uses the fatal boundary rather than silently losing the outcome.

A worker cannot close its own executor: WorkerSelfJoinException is raised before
the owner's lock/transition, even if an external thread is already draining.
If not caught in the callable, it is observed by the external handle's get.

Uncertain native Thread.start/join, escaped scheduler failures and an unproved
owner shutdown are **process-fatal** under the candidate lifecycle policy. They
emit a static diagnostic and abort rather than report a fictitious joined state
or unwind potentially borrowed storage. This tradeoff is separate from ordinary
task-error delivery and remains part of the draft policy review. Nonreturning
tasks may make shutdown wait forever. No finalizer silently closes an executor.

## Validation and remaining release gates

The public-only consumer tests typed/void results, repeated get, typed closed and
self-close errors, function/delegate submission, both capacity limits, automatic
budget reuse, dropped-handle GC graphs and concurrent external producers/closers.
Whole-source compile-negative fixtures cover @safe submission, noncopyable F/R,
nonassignable R, noncallables, handle/cell construction and internal access.
The lifecycle/native-failure gates remain required separately.

Run `python3 tools/validation/m0_public_api.py dmd` (or `ldc2`). Debug and release
are checked; LDC also checks assertions-on -O3. CI pins DMD 2.111.0 and LDC 1.41.0
and runs the same public gate on native ARM64.

A stable v0.1 release still requires review/acceptance of the lifecycle and public
contracts, a final public-path end-to-end baseline, license/package metadata,
version/tag/publication checks and recorded release-gate acceptance. The M1
Conditional candidate, source-pinned research and proposed TaskScope are not
silently imported into this API.

For an exploratory matched public/internal LDC release comparison, run
`python3 tools/validation/m0_public_path.py NEW-RESULT-DIRECTORY`. It records
alternating same-work pairs and checksums without a speed threshold. It does not
replace thermally controlled native release-performance qualification.
