# M0 native lifecycle boundary and worker self-close

Date: 2026-10-22. Status: **internal implementation candidate for review**.
Tracking: [lifecycle #12](https://github.com/alex-1974/concurrency-d/issues/12),
[safety #13](https://github.com/alex-1974/concurrency-d/issues/13),
[release gate #16](https://github.com/alex-1974/concurrency-d/issues/16).

## Problem and selected candidate behavior

The old internal pool counted a worker only after Thread.start returned, but the
qualified POSIX druntime implementations can throw after native launch. Its
sequential default joins could also throw without proving every worker stopped.
The owner then recorded the failure and published stopped. Retaining records in
that error branch did not prove quiescence or authorize caller-stack unwind.

A second issue was self-close: a worker joining itself could deadlock. Checking
only inside the raw pool is insufficient, because the owned executor may first
wait for an external controller already draining that same worker.

This narrow change chooses a **fail-stop implementation candidate** for uncertain
native lifetime. It does not implement recoverable failed-OS-join recovery or
approve a public TaskScope. The public API/contract remains separate; the change
must be reviewed and qualified before merging to develop.

## Behavior

- A D thread-local pool identity is installed once around the whole worker loop
  and restored at exit. No per-task identity lookup, new queue lock, notifier
  policy or dispatch callback is added.
- Both raw pool and owned close reject a same-pool worker using a dedicated
  WorkerSelfJoinException. The owned guard runs **before** its lifecycle mutex,
  running-to-draining transition or draining wait. A rejected call leaves state
  unchanged. The existing owned thunk records this as an ordinary task failure
  if the callable does not catch it.
- A worker of a different pool may close an independently idle/drainable pool;
  cycles between pools and same-pool unmet-handle waits are not solved.
- Every Throwable escaping native start triggers the START fatal boundary. It
  may represent post-launch uncertainty, so caller `_started` accounting is not
  used as proof that the failing worker never existed.
- Allocation/worker-construction errors **outside** the native-start wrapper
  remain recoverable when confirmed earlier workers have been closed and joined.
- Owner mutex/condition allocation now occurs before creating the native pool.
  Previously a later owner allocation could unwind after starting an idle pool
  with no cleanup path. The pool is now the last constructor operation.
- Native joins use join(false). A thrown native join error triggers JOIN fatal;
  a returned unhandled worker Throwable is distinguished and triggers WORKER
  fatal. Unexpected Throwables escaping the worker loop also trigger WORKER.
- Failure of the inbox close transition triggers CLOSE fatal. Successful join
  must satisfy the drained obligation predicate before returning (DRAIN fatal
  otherwise). The owned layer adds an OWNER fatal boundary around unexpected
  pool-close failures and publishes stopped/clears final roots only after success.
- Fatal paths emit a static C stderr marker and call abort. They do not allocate
  a new D diagnostic or promise availability under runtime corruption or blocked
  diagnostic I/O. These are process-wide fatal outcomes, not retryable Exceptions.

Ordinary task Exceptions and the existing owned-thunk behavior for a deliberately
thrown Error remain observable through result handles. This is not a promise of
recovery from arbitrary Error/runtime corruption. Completion-ready still differs
from the returned marker and from successful worker join.

## Scope and source provenance

The source rationale is retained in
[P07's pinned druntime audit](https://github.com/alex-1974/concurrency-d/blob/research/m1-task-lifetime-boundaries/research/m1_task_lifetime/prototypes/p07_native_lifecycle/README.md).
It distinguishes ThreadError from native ThreadException and join(false)'s
returned worker error. The current local DMD 2.111.0 and LDC 1.42.0 runtime source
was also inspected for these boundaries. CI continues to pin DMD 2.111.0 and LDC
1.41.0; Linux x86-64 and native ARM64 are the configured execution targets.

No invalid pthread_join, native handle corruption, actual pthread_attr_destroy
failure, OS join recovery, other-OS runtime audit or global scheduling/liveness
proof is claimed. Nonreturning tasks may still prevent shutdown indefinitely.

The M1 research branch, original P42 performance sources, all source pins and
Draft PR #38 remain unchanged. Old source-pinned experiments intentionally
reject this changed source if someone tries to transplant them mechanically.
Conditional publication, TaskRef representation and queue policies are not
changed or promoted by this lifecycle work.

## Validation

The checked-in internal consumer in tests/lifecycle covers eight rounds of:

- owned self-close while running, handle rethrow and continued admission;
- owned self-close only after an external controller has entered draining;
- raw pool self-close rejection, successful external join and exact completion;
- allowed cross-pool close, ordinary task Exception and recorded Error behavior;
- post-join record clearance and repeated successful external shutdown.

The validation runner builds the current actual source in isolated temporary
DUB packages. Normal-path fixtures are unmodified. For exceptional branches it
creates separately compiled source overlays with single-use anchors:

| Synthetic probe | Expected result |
|---|---|
| ThreadError immediately after real start, before accounting | SIGABRT + START marker |
| Thrown join failure with a real blocked task live | SIGABRT + JOIN marker |
| Inbox-close failure with a real blocked task live | SIGABRT + CLOSE marker |
| Throwable escaping the worker delegate | SIGABRT + WORKER marker |
| Worker Throwable returned after a successful real join | SIGABRT + WORKER marker |
| Failed drain predicate after real joins | SIGABRT + DRAIN marker |
| Unexpected owner-to-pool shutdown failure with blocked task live | SIGABRT + OWNER marker |
| Known construction failure before worker 0/1 launch | original Exception; exactly 0/1 confirmed real joins |
| Owner condition setup failure | original Exception; no native start occurred |

Each fatal probe runs as its own bounded native subprocess, with core dumps
disabled. A required marker **and** SIGABRT are checked; assertion failure,
compiler failure, timeout or unrelated nonzero exit cannot count as PASS.
Production modules contain no test-only fault flags. These probes verify handling
of **simulated** uncertain returns, not reproduction of real OS failures.

Run `python3 tools/validation/m0_lifecycle.py dmd` or the corresponding ldc2
invocation. DMD/LDC cover debug and release; LDC additionally covers debug -O3
with assertions enabled. The existing CI matrix and native ARM64 job run this
same gate. The separate tests/lifecycle DUB package can also run directly against
the actual library dependency. Unit and portable parking checks remain required.

## Remaining work

A public facade, supported capture/copy constraints, independent public consumer,
license/package qualification and public release acceptance remain open. The
fail-stop policy is consequential: merge/release review must accept this explicit
availability tradeoff or replace it with a separately qualified ownership policy.

## Local receipt

DMD 2.111.0: debug/release normal paths and all ten synthetic probes PASS.
LDC 1.42.0: debug/release and assertions-on -O3 normal paths and all ten probes PASS.
Root unit tests pass on both compilers (five modules). The separately linked
internal lifecycle consumer passes on both. The optimized LDC portable parking
smoke completes with drained/joined workers; its timing is diagnostic only and
is not a matched speedup/regression result. Pinned CI and native ARM64 evidence
must be recorded at the published code commit before qualification is claimed.
