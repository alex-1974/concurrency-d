# M0 public executor contract — proposed release slice

Date: 2026-10-22. Status: **PROPOSED, not an exported API or accepted native-failure policy**.
Tracking: [M0 goal #5](https://github.com/alex-1974/concurrency-d/issues/5),
[release gate #16](https://github.com/alex-1974/concurrency-d/issues/16),
[lifecycle #12](https://github.com/alex-1974/concurrency-d/issues/12),
[lifetime #17](https://github.com/alex-1974/concurrency-d/issues/17).

## Outcome

Ship a small explicitly controlled CPU executor that an independent D package
can create, submit copyable tasks to, obtain typed results from, and drain.
General TaskScope, borrowed-task safety, cancellation, fibers and sender/receiver
interoperability are separate M1/M2 work. The existing eight-byte TaskRef and
containers-d deque remain internal implementation details.

This contract narrows the public release problem without claiming that current
internal classes already satisfy every requirement. See the
[M0 readiness ledger](m0-release-readiness.md).

## Candidate public surface

Names are provisional; these signatures describe the minimum behavior to
implement and qualify, not declarations consumers can compile today:

```d
class Executor;
class TaskHandle(R);

// Construct Executor with explicit worker, ingress and retained-record limits.
// Executor.trySubmit(F): TaskHandle!(ReturnType!F), null on bounded capacity.
// Executor.submit(F): retry capacity rejection; return handle or report close.
// Executor.closeAndJoin(): stop admission, drain accepted work, join workers.
// TaskHandle!R.isComplete(): synchronized result/error readiness observation.
// TaskHandle!R.get(): wait and return a copy of R, or rethrow task failure.
// TaskHandle!void.get(): wait and return void, or rethrow task failure.
```

Do not export diagnostic counters, raw TaskRef, local queues, root registries or
worker indices as part of this initial API. Maintenance/reclamation is an internal
responsibility; its explicit public exposure needs a real consumer requirement.

## Task and data contract

- Submission is explicitly `@system`. Copying a callable does not establish
  transitive ownership, referent lifetime, absence of races, or safe borrowing.
- The accepted callable value is copied into an address-stable GC-managed node.
  Its reachable GC-managed graph is retained while the node can be accessed by
  a worker. External/manual memory and caller-stack referents remain the
  caller's responsibility through the required quiescence point.
- F and non-void R must be copyable under the operations the implementation
  actually performs. Move-only values are excluded from v0.1 until separately
  implemented and tested. Define constraints/diagnostics in the public facade;
  do not imply support from an unconstrained generic signature alone.
- Result observation is repeatable and returns by value. Mutable reference
  results still require caller synchronization; a copied slice/class reference
  is not an independent deep copy.
- No deterministic destruction timing for GC graphs is promised. User copies,
  destructors and callbacks must not invalidate published storage, reenter
  executor shutdown, or rely on destructor-based joining.
- Dropping a task handle does not cancel accepted work. Keep the executor
  explicitly rooted and accessible until closeAndJoin has succeeded.

## Admission and backpressure

Successful publication creates exactly one execution obligation. Rejection
creates none. Install retention before exposing the TaskRef to workers.

`trySubmit` is nonblocking with respect to capacity, but may acquire locks and
allocate for successful admission. Null means ingress or retained-record budget
is currently exhausted. Known full rejection preserves the existing early
allocation gate. An attempt that observes draining/joined reports a dedicated
closed-executor exception rather than returning an ambiguous null.

`submit` retries only capacity rejection outside the admission lock; it can wait
indefinitely if accepted work never finishes. No timeout, fairness, real-time or
starvation-freedom guarantee is implied. It must observe concurrent close and
terminate with the documented closed exception.

## Results and ordinary task failures

A handle owns its result/error cell independently of the task node. Result-ready
is not a record-reclamation or worker-join certificate. Reclaim records only after
the release/acquire returned marker; release all remaining records only after
successful native worker join.

An ordinary task Exception is recorded for that task, siblings continue, and
get rethrows the recorded failure. Shutdown still drains accepted work. The
current internal thunk catches Throwable; this does not establish that every
Error, runtime corruption, native synchronization failure or out-of-memory path
is safely recoverable. Public wording and fatal-Error behavior need explicit
qualification before release.

## Threading and blocking restrictions

Multiple external producers and external shutdown callers are supported.
Admission and the first close transition linearize under the same mutex.
One closer performs native joins; others wait for the same outcome.

There is no helping or worker compensation in M0. A worker must not block on an
unmet task that requires capacity from the same exhausted executor. Calling
closeAndJoin from one of its own workers must be rejected before entering join;
add worker-identity detection and a targeted negative test. Nested spawn is not
itself prohibited, but does not authorize blocking nested joins or infinite
capacity retry on an exhausted pool.

Workers never mutate consumer GUI/event-loop state through this API. The consumer
observes results and applies completion on its own thread. The P42.20 CPU/handoff
fixture demonstrates this limited pattern; it is not a GUI framework adapter.

## Shutdown and native uncertainty — release-blocking decision

Normal successful lifetime:

```text
running -> draining -> joined
```

Close rejects new work, drains every accepted obligation, joins all workers and
only then reports success. Repeated/concurrent external close calls observe the
same success. No destructor or GC finalizer silently substitutes for explicit
close. A task that never returns may prevent close from returning.

**Current implementation gap:** the internal owner sets `Lifecycle.stopped`
after catching a native join failure. Retained nodes are preserved in that
branch, but worker quiescence and safe stack unwind have not been established.
Likewise a native start may fail after launch but before the caller increments
its started-worker count. Neither path meets a public successful-join contract.

**Recommended first M0 policy, still proposed:** use a documented fail-stop
boundary if native startup/join outcome leaves any worker lifetime uncertain.
Never unwind normally into release of potentially borrowed storage; never label
that outcome joined/stopped-success. Keep ordinary task Exception delivery
recoverable and separate. A process-wide abort is a consequential API policy and
must be accepted explicitly as part of the public contract, with source-pinned
subprocess fault-injection tests and a native lifecycle audit.

If recoverable native uncertainty is required instead, select and implement an
independently rooted supervisor/owned-capture policy first. The P23–P29 research
is supporting evidence, not a complete failed-OS-join recovery implementation.
Do not export the current internal owner unchanged while that decision is open.

## Release acceptance

1. Settle the native-failure boundary and qualify actual start/join/error paths.
2. Implement the small facade, copyability diagnostics and self-close rejection.
3. Run a separate DUB package importing only the public module: typed/void/error,
   bounded admission, dropped handles, GC graph, repeat get, concurrent close,
   compile-negative safe/copy constraints and supported architecture checks.
4. Verify public exports and public Ddoc, supported compiler/dependency pins,
   package metadata and the release/tag/publication procedure.
5. Record representative original-control end-to-end performance. Conditional
   promotion has its own review/evidence gate; a usable M0 does not require a
   general TaskScope or merging the entire research branch.
