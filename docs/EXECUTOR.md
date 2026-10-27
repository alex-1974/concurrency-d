# Public CPU executor and M1 scope prototype

The v0.1.0 release exports the M0 API through `import concurrency`. The v0.2.0
candidate on `develop` adds a lexical scope and typed two-way join. Those
additions are not part of the published v0.1.0 archive and await exact-candidate
qualification before release.

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

Run the checked-in independent CPU and event-loop-style consumers from the
repository root:

```sh
dub run --root=examples/cpu-executor --compiler=dmd
dub run --root=examples/cpu-executor --compiler=ldc2 --build=release
dub run --root=examples/event-loop-consumer --compiler=dmd
dub run --root=examples/event-loop-consumer --compiler=ldc2 --build=release
```

Both examples import only the public module. The CPU example computes and
validates 48 independent chunks through both typed handles and `parallelFor`;
the range callback writes to per-index slots and the controller reduces them
after the implicit join. The event-loop example has workers post
completed values into a synchronized queue owned by the consumer; its
controller thread alone updates application state. It also exercises
cooperative cancellation, lexical draining, result retrieval after shutdown,
and controller/worker thread affinity. The queue is the intended adapter seam
for a future GUI dispatcher: the library does not own or call a UI framework.
These are executable integration examples, not latency claims.

## Surface

| Symbol | Behavior |
|---|---|
| `Executor(workers, ingressCapacity, maxRetained = 4096)` | Explicit positive limits; setup completes before native worker startup |
| `executor.trySubmit(callable, workSize = WorkSize.small)` | One attempt: typed handle on success, null on bounded capacity, ExecutorClosedException after close |
| `executor.submit(callable, workSize = WorkSize.small)` | Retry capacity rejection until admitted or closed; may wait indefinitely |
| `executor.parallelFor(itemCount, grainSize, body)` | Run `body(index)` over `[0, itemCount)`; workers dynamically claim contiguous ranges of up to `grainSize`, and all workers are joined before returning |
| `executor.parallelForAdaptive(itemCount, minGrainSize, body)` | Run indexed work with guided claims that begin larger and shrink toward `minGrainSize`; all workers are joined before returning |
| `executor.withScope(maxTasks, body)` | Provisional M1 API: run a bounded lexical child group, drain on body unwind, then propagate child errors |
| `executor.join(left, right, leftWorkSize = WorkSize.small)` | Provisional M1 API: schedule `left` as one scoped child, execute `right` inline, join both, and return typed non-void fields |
| `TaskScope.spawn(callable, workSize = WorkSize.small)` | Submit a child and keep its post-dispatch join obligation in the scope |
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

For workloads made of many independent indexed items, use
`parallelFor(itemCount, grainSize, body)`. The calling thread participates,
alongside up to `workerCount - 1` executor tasks, which claim contiguous ranges
as work becomes available. This amortizes task admission while redistributing
uneven work. Small grains improve balancing but increase atomic claims; large
grains reduce claims but can leave a long tail. The matching
sweep in [the end-to-end benchmark](../benchmarks/README.md) compares several
grain sizes. `grainSize` is the maximum number of indices claimed at once, not
the worker count or a time estimate. For opaque tasks or custom dependencies,
use `submit` and choose the task grouping explicitly.

`parallelForAdaptive` is an opt-in alternative for workloads with many cheap,
uniform items. Its `minGrainSize` guides claim sizes: early claims may be
larger, and the final partial claim may be smaller. This reduces claim
coordination when much of the domain remains while keeping smaller claims near
the end. If the minimum is at least `itemCount`, the whole domain is one claim
and runs on the calling thread. It can worsen load balance when item costs
vary; use the fixed-maximum `parallelFor` when a
strict upper bound per claim matters. A focused local sweep found that minimum
1 greatly reduced median time over fixed grain 1 at two and four workers,
including short and variable-cost items. A follow-up found that a cluster of
expensive items at the start can make guided claims slower, so item-cost
distribution matters as well as its range. After tuning both methods
independently, their best medians were
usually within about 5% on the tested scattered and uniform workloads, and
fixed claims sometimes led. Use adaptive claims when a small lower bound is
useful across uncertain costs; use fixed claims when costs cluster or a hard
per-claim upper bound matters. Benchmark both methods for peak performance.

The caller may also pass `WorkSize.large` to `submit`, `trySubmit`,
`TaskScope.spawn` or `join` when a callable is expected to run substantially
longer than ordinary work. Workers
then claim that task alone from shared ingress rather than prefetching it with
the next tasks, leaving more queued long tasks visible to other workers. The
default `WorkSize.small` preserves the existing bounded inbox batch policy.
This hint does not split a callable, change its priority, predict its runtime,
or promise that all workers will be busy; use application-level batching for
many tiny independent items. The streaming benchmark can compare both hints.

## Performance tuning

Treat these values as workload-specific starting points, not promises or
universal defaults. Tune against the application path and the metric that
matters: throughput, completion latency, tail latency, or producer time blocked
by backpressure. Improving one can worsen another.

| Parameter | Starting approach | What to watch |
|---|---|---|
| `workers` | Begin near the CPU capacity available to this process. Sweep around that point, including fewer workers when producers, callbacks, or other application threads also need CPU. | Throughput and tail latency; extra workers can add scheduling and cache contention. |
| Batch size | For many tiny independent items, sweep roughly 1, 4, 16, 64, 128 and 256 logical items per submitted callable. Keep enough batches to occupy all workers; use smaller batches when items vary greatly in cost or low latency matters. | Task-record/admission overhead versus idle workers and time spent waiting for the slowest item in a batch. |
| `grainSize` | With `parallelFor`, start at 1 and compare 4, 16, 64, 128 and 256 against real work. Tiny or uneven items often benefit from small claims; larger claims reduce counter traffic for very cheap, uniform items. | Atomic claim overhead versus load balance and the final slow range. |
| `minGrainSize` | With `parallelForAdaptive`, start at 1 for many uniform items, then compare against fixed-grain `parallelFor`. | Fewer claim operations versus tail latency and imbalance when item costs vary. |
| `WorkSize` | Use `large` only when the callable is expected to run materially longer than ordinary work; otherwise keep the default `small`. | Long-task distribution versus inbox lock amortization. The hint is an estimate, not a measured duration or an automatic split policy. |
| `ingressCapacity` | Start with a few queued tasks per worker, then test a small range such as 1x, 2x, 4x and 8x the worker count. | Rejection/retry or producer blocking, queueing latency and memory. A larger inbox absorbs bursts; it does not by itself increase steady-state processing capacity. |
| `maxRetained` | Keep the default unless the application's retained-task pattern gives a reason to change it. Size for accepted records that may not yet have returned, including active scoped parents and children. | `trySubmit` rejection under load and retained memory. This is a record-count bound, not a byte limit or a count of all tasks over the executor's lifetime. |
| Producers | Start with the application's natural number of submitting threads; for a benchmark, compare one producer with a few concurrent producers. | Admission contention and producer wait time. More producers do not create more worker capacity. |

Change one parameter at a time, then check promising combinations. Keep the
logical work and validation identical between runs, warm up the executable,
collect repeated samples, and use an optimized build. Record compiler/version,
worker and producer counts, both capacity limits, batch size, CPU and power
profile. The [benchmark guide](../benchmarks/README.md) has reproducible
commands for the repository's grain-size and bounded-streaming sweeps. Those
microbenchmarks help explain costs; choose final settings using representative
application tasks. Large batches and queues can improve throughput while
raising latency, so prefer the smallest values that meet the application's
throughput target without violating its latency needs.

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
already present. The v0.2.0 candidate applies the narrowly selected conditional
publish-notification policy from
[ADR-0003](adr/0003-coalesce-idle-publish-notifications.md); it and the
candidate TaskScope implementation remain separate from the released v0.1.0
API.

For an exploratory matched public/internal LDC release comparison, run
`python3 tools/validation/m0_public_path.py NEW-RESULT-DIRECTORY`. Use
`--iterations 2048` to select a longer per-task CPU kernel; the default is 128.
It records alternating same-work pairs and checksums without a speed threshold.
It does not replace thermally controlled native release-performance
qualification.
