# M1 P22 — Independent owner with real native workers

**Date:** 2026-10-15. **Status:** bounded native-lifecycle research,
**not** a public/production executor and **not** a completed native
failure-recovery proof.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Depends on:** [P07](../p07_native_lifecycle/README.md)
(druntime start/join source audit),
[P09](../p09_transfer_contract/README.md)
(supervisor retention model),
[P20](../p20_owned_native_unknown/README.md)
(actual M0 false-stopped witness),
[P21](../p21_shutdown_contract/README.md)
(finite-state shutdown contract).

## Question and boundary

Can a **separately rooted owner** hold accepted GC-managed work for real
`core.thread.Thread` workers, serialize concurrent closing controllers,
preserve roots after an injected uncertain shutdown, and release them **only
after a verified successful native join**, while denying consumer-level
root release before then?

The [P22 implementation](concurrency/research/m1_p22_native_supervisor.d)
is a **standalone two-worker native druntime probe**, not a copy of
`source/concurrency/internal/submission_pool.d` and **not** an executor
for arbitrary user `TaskRef` or callbacks. It uses real
`Thread.start()`, `Thread.join(false)`, a Mutex+Condition lifecycle,
a separate `OwnerSupervisor`, two GC-owned linked payload objects per
worker, and semaphores for deterministic test rendezvous.

The complete experiment is intentionally bounded: two worker slots,
three shutdown callers, a small set of **known synthetic faults**,
separately held GC roots and ordinary native join success.

The runner verifies both original production files remain byte-identical
to the previously qualified M0 Git blobs:

- `submission_pool.d`: `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`
- `owned_task.d`: `e74d6a73f956c562eab176e27687a47249f5815d`

No production `source/`, public DUB API, storage layout, M0 work-stealing
queue, benchmark source, or unrelated repository is modified.

## Ownership / state protocol actually implemented

**Prelaunch root.** Before any `Thread.start()`, the controller creates
`RootedGroup` and gives an independent **strong reference** to
`OwnerSupervisor`. Before the worker can run, the group allocates and
stores each `Payload` graph and installs the corresponding `Thread`
object, then marks that slot `possiblyStarted` prior to calling
`start()`. The worker delegate captures its own task arguments via a
separate `makeWorker` invocation frame; it does not borrow a reused
`foreach` variable.

**Shutdown arbitration.** `closeAndJoin()` transitions one controller
from `running → draining` under a mutex. Exactly that controller becomes
the join owner. Contending closers observe `draining`, increment an
observable waiter count, and sleep on the Condition until resolution;
later closers see the stable `uncertain` or `joinedStopped` result.
Root cleanup occurs only after successful `join(false)` calls for every
launched worker. A returned user Throwable from `join(false)` is distinct
from a native join exception; worker errors are intentionally fail-stop in
this bounded harness.

**Unknown native error policy.** A **real** `Thread.start()` Throwable
after possible launch is **fail-stop** (`abort()`), because a recoverable
return would allow the caller to abandon a group with potentially live
workers. A **real** `Thread.join(false)` Throwable is also fail-stop.
This does **not** solve a generic production fault-tolerant shutdown;
it is the conservative research-only response chosen rather than
inventing native join retry or after-abandonment reachability guarantees.

**Known synthetic injections.** Two test hooks are narrower than actual
OS faults and remain distinguishable:

1. A controlled `syntheticPreJoin` fault is injected while the elected
   closer is blocked **before any native join call**. Both other closers
   must demonstrably enter the `draining` wait path before injection is
   released. All three then observe `uncertain`.
2. A `syntheticPostLaunch` fault is injected **after a real
   `Thread.start()` returned successfully** but before its slot is
   upgraded from `possiblyStarted` to `started`. The retained `Thread`
   object represents an actually created worker, even though the modeled
   startup registration was interrupted.

For **those test-only proven injection origins**, the supervisor may
eventually allow the gate to open and invoke real successful joins.
This is **not** permission to retry a native `pthread_join` that itself
failed; none was attempted on the injected failure path. Root cleanup
after a successful join cannot retroactively prove that an arbitrary
`@system` borrowed capture was safe.

**Root separation.** The test controller drops its `RootedGroup` handle
while `OwnerSupervisor` still holds the group. Four forced GC collections
occur before the known synthetic prejoin case is resolved. The separate
supervisor denies `tryDiscard()` until `joinedStopped`, then verifies
the retained payload graph has been cleared and relinquishes the group
reference.

D's conservative GC and worker delegate closures may hold additional
references. Consequently P22 proves an **explicit strong retention path**,
not uniqueness of the supervisor as a GC root, no leaks under arbitrary
abandonment, or transitive ownership of pointer-bearing user tasks.

## Deterministic scenarios and executable gates

The [runner](../../../../tools/research/m1_p22_native_supervisor.sh)
compiles the actual standalone D source directly using pinned
DMD 2.111.0 and LDC 1.41.0 with `-preview=dip1000`, executes normal
and **whole `-release`** binaries, and additionally executes LDC
`-O3` **with assertions on**. Every native executable is timeout-bounded;
the harness requires the exact final marker.

Within **each executed configuration**:

| Scenario | Repetitions | Observed invariants |
|---|---:|---|
| Normal multi-controller shutdown | 12 | Two joined real workers; three closer results `joinedStopped`; exactly one elected join owner; both results and final root release checked. |
| Injected pre-join fault | 12 | One elected closer stalls before join; both other closers **observed waiting** during `draining`; all return `uncertain`; premature release rejected; four forced GCs; supervisor then performs real native joins and releases roots. |
| Injected post-launch start fault | 8 | `Thread.start()` really returned for the first worker; startup registration intentionally remains `possiblyStarted`; `uncertain` does not imply quiescence; supervisor joins the known launched thread before release. |

Every runtime oracle uses an always-evaluated `require()` rather than
potentially elided `assert()` calls. In the close-race controls the
per-thread result slice is passed through a **separate function invocation
frame**, correcting an early P22 harness defect where direct
`foreach`-local captures could alias a reused iteration activation.

Run from repository root:

```sh
bash tools/research/m1_p22_native_supervisor.sh dmd
bash tools/research/m1_p22_native_supervisor.sh ldc2
```

The required marker is:

```
P22_NATIVE_SUPERVISOR_PASS normal=12 prejoin=12 postlaunch=8
```

**Exact executable source commit:**
[`eaf3149d1993435a9a3d37d35b1b5457968b24bc`](https://github.com/alex-1974/concurrency-d/commit/eaf3149d1993435a9a3d37d35b1b5457968b24bc).
**Code CI:** [Actions #38722022400](https://github.com/alex-1974/concurrency-d/actions/runs/38722022400):
P22's repeated native-worker gate passed **under both pinned compiler
jobs**, including whole-release execution; LDC also used optimized
`-O3`. Check overall P01–P22 workflow conclusion and final documentation
HEAD separately.

## What P22 supports, and what it cannot establish

**KEEP for M1 design:** explicit owner installation before launch;
`possibleStart` is different from `joined`; a single join owner with
waiting concurrent controllers; distinct normal and unproven shutdown
outcomes; no early owner-root release; a real successful join is
mandatory for test cleanup. These observations complement P21's
single-threaded finite-state proof with **real native concurrency**.

**NO-GO for production promotion:** The source does **not** exercise the
real M0 `TaskRef` queues, multi-producer submissions, work stealing,
worker-side task exceptions, per-record reclamation, cancellation, or
arbitrary user callbacks. It does not simulate an actual native
`pthread_join` failure, and its `Thread.start()` postlaunch branch is
an injected exception after a known successful launch. There is no
qualified cross-platform Windows/macOS lifecycle policy, persistent
process-wide supervisor, retry after native join error, independent
owner reachability after **all** owners disappear, nor an acceptable
high-availability error contract. Ordinary `@system` captures remain
`@system`; P22 does not imply general `@safe TaskScope`.

## P23 real M0 lifecycle follow-up

[P23's source-pinned original-owned-executor experiment](../p23_real_owned_lifecycle/README.md)
now tests the deferred-start and separately held owner **against the
unchanged real M0** `SubmissionWorkerPool`, `TaskRef`, `OwnedNode`,
backpressure and worker completion accounting rather than P22's separate
two-worker skeleton. It adds three concurrent closers, known synthetic
pre-join and post-successful-start cases, nested GC capture retention,
and a four-producer shutdown race. Real native start/join failures
remain **fail-stop**; the research supervisor is not yet a durable
process-level owner, nor does it imply a general `@safe` API.

**Next bounded integration gate:** explore a separately named research
wrapper/adaptation around the real M0 `OwnedTaskExecutor` with
per-worker native lifecycle proof and an independent **prelaunch**
retention root; explicitly test producer/close races, refused release
during unproven shutdown, completed-task reclamation, and worker
`Throwable` versus failed OS join. Compare performance only after
ownership and availability semantics match, and preserve the unchanged
original M0 as a control.

Keep [ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md)
PROPOSED, Issue #17 OPEN, PR #38 DRAFT, and grandfathered PR #35
untouched. No merge or production changes.
