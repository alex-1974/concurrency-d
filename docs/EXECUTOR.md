# Public CPU executor and M1 scope prototype

The v0.1.0 release exports the M0 API through `import concurrency`. The current
development branch also contains a provisional M1 lexical-scope prototype;
that addition is not part of the v0.1.0 archive and is not yet a stable API.

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
| `executor.withScope(maxTasks, body)` | Provisional M1 API: run a bounded lexical child group, drain on body unwind, then propagate child errors |
| `executor.join(left, right)` | Provisional M1 API: schedule `left` as one scoped child, execute `right` inline, join both, and return typed non-void fields |
| `TaskScope.spawn(callable)` | Submit a child and keep its post-dispatch join obligation in the scope |
| `TaskScope.cancellationToken()` / `requestCancellation()` | Cooperative request signal; tasks poll the token, and the scope still joins every child |
| `TaskScope.join()` | Wait for every child to stop accessing its record, then rethrow the first child failure |
| `executor.closeAndJoin()` | Stop admission, drain, join; repeated/concurrent external calls coordinate |
| `TaskHandle!R.isComplete()` | Synchronized result/error readiness; not last worker access |
| `TaskHandle!R.get()` | Wait, return a copy of R (or void), or rethrow the stored task failure; repeatable |
| `ExecutorClosedException` | Submission observed draining/joined executor |
| `WorkerSelfJoinException` | Same-pool worker tried to close its executor; rejected before waiting |

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
@safe capture contract is claimed. The provisional TaskScope API is also
`@system`; its body and child callables must not outlive the call to
`withScope`.

## Provisional M1 lexical scope

`withScope` preallocates a fixed `maxTasks` join list before invoking its body.
The limit is the total number of children in that scope, not just simultaneous
work. `spawn` uses the executor's retrying submission path, so it can wait
indefinitely for bounded executor capacity. No child can be detached. Call
`join` explicitly if the body needs to observe child failures before it returns;
otherwise `withScope` joins automatically on normal return and on exceptions.
Nested and recursive `withScope` calls from either the external controller or
a worker are supported. A worker helps execute available same-pool tasks while
retrying admission and joining children. Size `maxRetained` to cover active
parent and child records; a saturated budget or a callback blocked on
unavailable work can still prevent progress.

Each scope has a copyable `CancellationToken`. The body can request cancellation
and child tasks can poll `isCancellationRequested()`. This is only a cooperative
signal: it does not interrupt a callback, cancel queued work before execution,
or permit early reclamation. The scope still waits for every accepted child,
including after a cancellation request; a child that ignores the token can make
the join wait indefinitely. Task failures do not automatically request
cancellation of siblings. All token copies share one idempotent request bit.
A request racing callback completion does not compete with result publication:
the callback executes once, and its ordinary value or failure remains the one
repeatable `TaskHandle` outcome. A token is not an independently cancellable
result observer, and dropping or retaining a token does not cancel or retain an
underlying task. An escaped token may still report the request after scope exit,
but it has no executor effect after all children have joined.

The scope waits for a separate post-dispatch return marker. A result becoming
ready is earlier and is not enough to let borrowed task storage expire. After
the join, completed task nodes are removed from the executor's retained set;
the result handles remain valid. If the body throws, `withScope` drains accepted
children and then rethrows the body's exception. On normal return, it drains
every child before rethrowing the first child failure. Worker helping applies
only to scoped admission and post-dispatch joins. A child that blocks in an
ordinary `TaskHandle.get()` can still deadlock if its awaited work needs the
same exhausted executor.

The scope is controlled by the thread that called `withScope`; sharing the
scope object with other threads is outside the `@system` contract. The body
delegate and every borrowed referent must remain valid until `withScope`
returns. `TaskScope` disables ordinary copying. Explicitly moving its public
view may reset the source view, but cannot move the join obligation: the
`withScope` frame retains the internal state independently and always drains it.

`Executor.join(left, right)` is the two-way convenience path. It schedules
`left` through a one-child scope and invokes `right` directly on the calling
thread. This avoids scheduling and allocating a second task record and lets a
recursive caller continue down one branch while workers can take the other.
It returns a `JoinResult!(L, R)` whose `left` or `right` field is omitted when
that callable returns `void`. Both branches finish before return. If the inline
branch throws, the forked child is still drained before that exception escapes;
if the inline branch succeeds and the forked child fails, the child exception
is rethrown. The caller chooses which branch runs inline, so this helper makes
no balancing or speedup promise.

This small fork-join helper and lexical scopes are the provisional v0.2
composition surface. [ADR-0004](adr/0004-defer-sender-receiver-layer.md)
defers a general lazy Sender/Receiver adapter until a concrete consumer needs
execution-context handoff or asynchronous operation graphs. `TaskHandle`
readiness is not silently presented as structural completion, and cooperative
cancellation is not converted into a separate cancelled outcome.

This is an initial bounded API candidate. It does not make arbitrary captures
safe, does not prevent a caller from deliberately escaping borrowed pointers
through `@system`, and has no v0.1.0 compatibility promise. Its compiler and
runtime gates are recorded in
[ADR-0002](adr/0002-task-lifetime-families.md); the provisional public contract
still awaits release acceptance.

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
owner shutdown are **process-fatal** under the accepted M0 lifecycle policy. They
emit a static diagnostic and abort rather than report a fictitious joined state
or unwind potentially borrowed storage. This tradeoff is separate from ordinary
task-error delivery and provides no native OS recovery. Nonreturning tasks may
make shutdown wait forever. No finalizer silently closes an executor.

## Validation and remaining release gates

The public-only consumer tests typed/void results, repeated get, typed closed and
self-close errors, function/delegate submission, both capacity limits, nested
and recursive lexical groups including single-worker helping under full ingress,
automatic budget reuse, dropped-handle GC graphs and concurrent external
producers/closers.
Cooperative cancellation is exercised while a child is running, before a later
child is published, while an accepted child is queued, across 64 request versus
completion races, and during 16 concurrent shutdown races. Every case still
waits for child return before borrowed scope data can expire, executes the
callback once, and preserves one repeatable result.
Whole-source compile-negative fixtures cover @safe submission, noncopyable F/R,
nonassignable R, noncallables, `TaskScope` value escape, handle/cell construction
and internal access. With DIP1000 explicitly enabled, an external positive probe
verifies an explicitly joined `@system` stack borrow. A compile-only limitation
probe also records that raw `TaskScope*` escape remains possible inside
`@system`; this is why no general `@safe` scope overload is claimed.
The lifecycle/native-failure gates remain required separately.

Run `python3 tools/validation/m0_public_api.py dmd` (or `ldc2`). Debug and release
are checked; LDC also checks assertions-on -O3. CI pins DMD 2.111.0 and LDC 1.41.0
and runs the same public gate on native ARM64. The gate includes the standalone
recursive scoped fork-join example at `examples/nested-scopes`.

The v0.1.0 release passed exact-commit CI and archive/version/tag/publication
checks. The scoped Dell XPS 15 / LDC 1.42 public-path baseline passed the
predeclared 10% bound for the two documented
kernels and 1P/1W plus 4P/4W scenarios; its machine-specific scope and result are
in [the M0 qualification record](M0-PERFORMANCE-QUALIFICATION.md). That result
is not a general performance guarantee. MIT and DUB license metadata are
already present. The M1 branch now applies the narrowly selected conditional
publish-notification policy from
[ADR-0003](adr/0003-coalesce-idle-publish-notifications.md); it and the
provisional TaskScope implementation remain separate from the released v0.1.0
API.

For an exploratory matched public/internal LDC release comparison, run
`python3 tools/validation/m0_public_path.py NEW-RESULT-DIRECTORY`. Use
`--iterations 2048` to select a longer per-task CPU kernel; the default is 128.
It records alternating same-work pairs and checksums without a speed threshold.
It does not replace thermally controlled native release-performance
qualification.
