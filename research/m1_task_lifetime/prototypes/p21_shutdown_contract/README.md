# M1 P21 — Concrete shutdown / ownership proof contract

**Date:** 2026-10-15. **Status:** bounded, executable **research
contract proposal**, not an accepted production API or proof of native error
recovery. **Research branch:** `research/m1-task-lifetime-boundaries`.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).
**Origin:** [P07 native source audit](../p07_native_lifecycle/README.md),
[P08 ownership boundary](../p08_owned_vs_borrowed/README.md),
[P09 external supervisor](../p09_transfer_contract/README.md),
[P19 real M0 retained graphs](../p19_real_owned_gc/README.md),
[P20 real M0 false-stopped state](../p20_owned_native_unknown/README.md).

## Scope and evidence strength

P20 demonstrated that the production-derived `OwnedTaskExecutor` sets
`Lifecycle.stopped` after a synthetic pre-join `Exception` while an accepted
worker can still be running and its record remains retained. Source findings
from P07 identify post-native-launch exceptions in the pinned
`Thread.start()` implementations and native `join(false)` failures that
do **not** establish quiescence. P09/P19 already distinguish an explicitly
retained owner from an independently held `TaskHandle`.

P21 provides a **small, finite protocol model** and precise design
postconditions instead of a third scheduler variant. It intentionally has
**no threads, GC, lock or raw TaskRef**. Its inputs represent independently
observed facts, not facts it can manufacture. The runner pins the unchanged
actual M0 source blobs (`owned_task.d`
`e74d6a73f956c562eab176e27687a47249f5815d`,
`submission_pool.d` `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`)
so a future source change forces a re-audit.

**Model source:**
[`m1_p21_shutdown_contract.d`](concurrency/research/m1_p21_shutdown_contract.d).
**Runner:** [`m1_p21_shutdown_contract.sh`](../../../../tools/research/m1_p21_shutdown_contract.sh).

## Two independent obligations

**Worker-quiescence obligation.** Each native worker slot has a separate
`absent`, `knownStarted`, `possiblyStarted` or `joinProven` state.
An exception from `Thread.start()` **after an actual launch might have
occurred** leaves `possiblyStarted`. An exception from the native
`Thread.join(false)` operation preserves the possibility that the worker
is still running. Only an **externally proven successful native join** (or
a separately established valid never-started proof) discharges that
worker's obligation. A value returned by `join(false)` representing a
worker's unhandled `Throwable` is distinct from a native join *throw*.

**Accepted-task outcome obligation.** An accepted `TaskRef` is an owed
execution/outcome, not simply a consumed inbox entry. Results may be ready
before post-dispatch worker return and cannot by themselves prove
quiescence. When workers have actually stopped while some accepted tasks
never returned from dispatch, those tasks need an explicit terminal
failure/cancellation outcome. A record cannot silently disappear.

The model uses `accepted`, `returned` and `canceled` counts and keeps
`returned+canceled <= accepted` invariant. `canceled` means a
**terminally resolved unexecuted obligation**, not a request that
automatically interrupts work. The model permits terminal settlement only
after `joinedStopped`: while a worker might still run, treating an
accepted task as canceled and freeing its graph would be unsafe.

## Proposed owner/worker state matrix

| Phase | Admission | Native worker certainty | Root release |
|---|---|---|---|
| `running` | Allowed while capacity and owner constraints hold | Workers may be starting or active | Executor/supervisor still owns accepted tasks |
| `draining` | Closed; shutdown claimed | At least one join outstanding | Not from phase or result-ready flag |
| `shutdownUncertain` | Closed; do not reopen on error | Join failure or post-launch start ambiguity remains | **Forbidden** without independent worker proof; keep supervisor rooted or fail-stop |
| `joinedStopped` | Permanently closed | All known/possible workers proven quiescent | **Only** after accepted outcomes are also settled |

The independent `supervisorRoot` owns the executor/records/capture graph
before controller abandonment; a `TaskHandle` retains its own result
cell, not the worker's complete graph. A `dropController` transition
cannot discard this supervisor root. A final `releaseRoots` requires
**all three** conditions: `joinedStopped`, every outstanding accepted
task settled, and supervisor ownership still present.

**Important conservative restriction:** this model keeps all aggregate
roots until full join. The real M0 owned executor already supports
individual post-dispatch record reaping with a release/acquire marker;
that separate proven per-record optimization need not wait for global
`joinedStopped`. Its safe coexistence with exceptional worker paths
must be reviewed separately. P21 does not outlaw individually proven
post-dispatch reclamation or create an additional per-task production
reference count.

## Executable checks / explicit negative transitions

The D model has no `@trusted` or `@system` bridge in its pure transition
logic. It uses `@safe pure nothrow @nogc` for its value-only state
transitions. Always-evaluated `require()` oracles execute in normal,
`-release` and LDC optimized builds.

The three directed cases require:

1. **Failed join + controller abandonment:** after entering
   `shutdownUncertain`, both further admission and owner-root release
   fail without changing state. Even a task's post-dispatch return cannot
   unlock root release. Only a separately input `nativeJoinProved`
   event makes `joinedStopped` and permits final release.
2. **Two workers / outstanding obligations:** one successful join is
   insufficient; a second native join failure keeps root retention
   required. After both joins are proven, two accepted but unexecuted
   tasks must receive terminal settlement **before** root release.
3. **Possibly post-launch start failure:** no work may be admitted after
   uncertainty. `certifiedNeverStarted` is an **external proof event**,
   not inferred from the original `Thread.start()` exception.

A separate bounded state-space traversal explores **all accepted and
rejected event combinations of length at most seven** from the initial
two-worker/two-task model. Invalid transitions must leave the complete
state unchanged. All reached states must preserve root, capacity,
outcome-accounting and native-quiescence invariants. This is an exhaustive
check **only within that finite model and depth**, not proof of all real
thread schedules, arbitrary number of workers, memory ordering or OS error
semantics. Results are counts of explored states and transitions, not
runtime performance metrics.

## P22 native supervisor follow-up

[P22](../p22_native_supervisor/README.md) implements a bounded version
of this proposal with **real druntime Threads**, an independently held
owner, three concurrent shutdown callers, mandatory waiter rendezvous,
and separate synthetic pre-native-join and post-successful-launch cases.
It repeats these controls under DMD/LDC, whole release and LDC
optimized correctness. Actual native start/join failures remain
**fail-stop**, not recoverable; no general M0 TaskRef or `@safe` API
follows. P22 is a separately named research-only implementation,
**not the production worker pool**.

## Implementation boundary for an eventual production change

**Proposed minimum components**, subject to a separate approved ADR and
source review:

- A lifecycle owner whose **strong retention root exists before any
  native launch**, is independent of transient producer/consumer
  handles, and remains reachable while worker status is uncertain.
- Per-worker native state that distinguishes known joined, known never
  started and possible post-launch start; join loops must attempt
  *every known joinable worker* without letting the first worker
  `Throwable` skip later joins. A native join exception is **not** a
  worker `Throwable` returned from successful `join(false)`.
- A terminal state that distinguishes completed successful shutdown from
  **unknown native quiescence**. Concurrent shutdown callers must see a
  coherent result and never construe `stopped` as proven joined.
- An outcome-settlement path for accepted tasks that did not run to
  completion, without confusing a cancellation request with completed
  cancellation.
- An explicit policy for unresolvable native uncertainty:
  **fail-stop** or independently retained unreachable-to-consumer roots
  with a documented availability/leak strategy. A retry is **not**
  automatically supported by these DMD/LDC POSIX findings; check
  Windows/macOS separately.
- For scope-bound borrows, **no normal unwinding** while a TaskRef might
  still reference an expired caller frame. External `@safe` must never
  be granted based on this model alone.
- Keep native status/ownership bookkeeping off the worker's
  per-task hot path where practicable. Production changes need
  semantically matched native LDC release benchmarks and tests after
  any API semantics have been fixed.

**NO-GO now:** automatically changing production
`OwnedTaskExecutor.closeAndJoin`, claiming reliable native join retries,
promoting general `@safe TaskScope`, or merging Draft PR #38.
The actual per-worker OS proof, independent-root retention and concurrent
controller/close implementation remain **OPEN** under Issue #17.

## Reproduce and status

```sh
bash tools/research/m1_p21_shutdown_contract.sh dmd
bash tools/research/m1_p21_shutdown_contract.sh ldc2
```

The runner checks exact actual-M0 Git blob identities, compiles and executes
the standalone model with `-preview=dip1000` in normal and D `-release`
under both pinned compilers, and with LDC `-O3` without `-release`.
Every native test process is timeout bounded; the output must match
`P21_SHUTDOWN_CONTRACT_PASS states=… edges=… rejects=…`.
**Source commit:** [`5f79ec63eb4fc959369bcb81faa18531810615e2`](https://github.com/alex-1974/concurrency-d/commit/5f79ec63eb4fc959369bcb81faa18531810615e2).
**CI evidence:** [workflow #38720146667](https://github.com/alex-1974/concurrency-d/actions/runs/38720146667).
Confirm the complete exact-head CI status before declaring the full
branch green.

Preserve `source/`, `develop`, `main` and the unrelated grandfathered
PR #35. Keep [ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md)
PROPOSED, Issue #17 OPEN and PR #38 Draft.
