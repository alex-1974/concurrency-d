# M1 P20 — Real-M0 owned executor: false `stopped` before native join

**Status:** real worker lifecycle with **synthetic pre-join failure**
qualified on pinned compilers; **NOT** a real failing `pthread_join`, generic
native-failure recovery, or public API change.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[PR #38 Draft](https://github.com/alex-1974/concurrency-d/pull/38).
**Precedents:** [P07 native druntime source/fail-stop](../p07_native_lifecycle/README.md),
[P08 ownership error semantics](../p08_owned_vs_borrowed/README.md),
[P09 isolated supervisor](../p09_transfer_contract/README.md),
[P19 real-M0 normal owned GC retention](../p19_real_owned_gc/README.md).

## New question, distinct from P09 and P19

P09 proved that an **isolated, independently rooted** controller model can
refuse to release a GC value while its native join is uncertain. P19 proved
the **actual unchanged OwnedTaskExecutor** normally retains nested GC
captured graphs across handle abandonment, forced GC and successful joins.

P20 addresses the still-missing **real executor state machine** question:

> Can the actual M0 `OwnedTaskExecutor.closeAndJoin()` claim
> `isStopped()==true` even though accepted worker work has not returned
> and there is no successful native join proof?

**P20 answer, for an injected pre-join Throwable: YES.** The source's catch
path stores a failure and unconditionally changes
`Lifecycle.draining → stopped`. That boolean/state does not distinguish a
failed join from completed native shutdown. The accepted task and its
GC-owned record remain live while a worker is still blocked.

## Exact source and fault boundary

Actual tracked source:
[`source/concurrency/internal/owned_task.d`](../../../../source/concurrency/internal/owned_task.d),
Git blob **`e74d6a73f956c562eab176e27687a47249f5815d`**.
Original unchanged scheduler:
[`source/concurrency/internal/submission_pool.d`](../../../../source/concurrency/internal/submission_pool.d),
Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**.

The [source-pinned P20 generator](../../../../tools/research/m1_p20_make_owned_fault.py)
checks the complete Git blob of `owned_task.d` **before** generating a
temporary differently named research module. It preserves the owned task
node/retention logic, original TaskRef, real M0 worker pool and its native
`Thread.start/Thread.join` implementation. It introduces exactly:

1. A one-shot research flag which throws a **synthetic `Exception` just
   before calling `_pool.closeAndJoin()`**, while the worker is provably
   blocked. It runs through the **existing** production catch/state
   transition code without modifying that logic.
2. A narrowly test-only method which, **after manually releasing the test
   blocker**, invokes the actual real pool's `closeAndJoin()`. Only after
   this has returned successfully does it clear accepted retained roots.
   An actual Throwable during that late native join **aborts the test
   process**, because this harness has no verified recovery contract.

The generated module is temporary and removed on runner exit; no generated
copy or injection code enters `source/` or the release package. This is
**fault injection at the library call site**, not corruption or deliberate
failure of an OS thread handle.

## Deterministic observed sequence

The [P20 consumer](../p11_real_pool/consumer/p20_fault_consumer.d)
uses the same P11 DUB dependency graph with the actual M0 package and
`containers-d 0.2.0`. All runtime checks are always-evaluated, including
D `-release`:

1. Start one genuine M0 worker running an accepted `OwnedJob` that
   blocks on a semaphore; it carries GC-managed `Gate` and `Receipt`
   references. Drop the submitting `TaskHandle`.
2. Create a distinct `OwnerSupervisor` that strongly retains the
   research-owned executor, and inject the pre-join exception.
3. `closeAndJoin()` throws the exact injected Exception. Verify the
   **production-derived state is `isStopped()==true`** although
   `accepted=1, completed=0, retained=1` and the worker has not passed
   its gate. This is a concrete **false-quiescence interpretation** of
   `stopped`, not a claim that the production code already frees the
   active record.
4. Drop the controller's own executor handle. Across four forced GC
   collections, the separate supervisor continues to own the executor,
   rejects early release, and observes the uncompleted task/retained root.
5. A `finally` releases the gate and forces the supervisor to perform
   a **real successful native join**, with fail-stop otherwise. Only now
   are the owned records cleared. Verify exactly one accepted/executed
   job, correct completion count and final supervisor root release.

The P20 test does not prove the GC would have collected the executor
without the supervisor: D is a conservative collector and other stack
roots can remain. It proves the explicit strong-reference path and
**the timing contradiction between `stopped` and actual quiescence** under
the injected failure.

## Executed D compiler gates

Run from repo root:

```sh
bash tools/research/m1_p20_owned_fault.sh dmd
bash tools/research/m1_p20_owned_fault.sh ldc2
```

The [runner](../../../../tools/research/m1_p20_owned_fault.sh) validates
the exact original blob and requires the explicit
`P20_OWNED_UNKNOWN_JOIN_PASS stopped_not_quiescent=1 real_join=1`
marker after actual worker execution in both debug and whole DUB release.
LDC additionally executes `-O3` with assertions retained. All spawned
processes have bounded timeouts. This is a correctness/research gate,
**never** a performance benchmark.

**Executable source commit:**
[`983f08980e261a3fdaacdf87d397e118cec9b394`](https://github.com/alex-1974/concurrency-d/commit/983f08980e261a3fdaacdf87d397e118cec9b394).
**CI:** [run #38718859048](https://github.com/alex-1974/concurrency-d/actions/runs/38718859048):
P20 step completed successfully on both pinned DMD 2.111.0 and
LDC 1.41.0, including release and LDC optimized execution. Check the
entire P01–P20 matrix conclusion separately; old generator attempts with
escaped literals and a broad source replacement were research-runner
defects corrected before this source commit.

## P21 executable contract follow-up

The [P21 shutdown/ownership protocol](../p21_shutdown_contract/README.md)
turns the P20 `stopped`/quiescence contradiction into an explicit finite
**two-worker, two-task state model**: external native join/never-started
proof, terminal settlement of unexecuted accepted work, independent
supervisor retention across caller abandonment, rejection of premature
root release, and bounded exhaustive checks of both permitted and
forbidden event transitions. These are **research constraints**, not a
claim that a D state-machine model proves the actual M0's native error
handling. Production `source/` remains unchanged.

## Engineering state contract — proposed, not merged

The P20 result supports separating a **shutdown request**, a **terminal
failure report** and a **native quiescence proof**; these are not synonyms.

| State / event | May worker still access an accepted TaskRef? | May records/capture roots be discarded? |
|---|---|---|
| `running`: admission allowed | Yes | Only individually proven post-dispatch returned records, if supported |
| `draining`: admission closed; join in progress | Yes | Not on shutdown-state name alone |
| **`shutdownUncertain`**: native start/join or join sequence unproven | **Yes, conservatively** | **No**; independently rooted owner required, or fail-stop |
| **`joinedStopped`**: actual successful native quiescence verified | No existing workers retain that execution graph | Yes, subject to result/consumer ownership |
| `Error` merely captured in a result cell | Possibly | No new TaskRef quiescence guarantee |

**Owned-family candidate:** an independently reachable worker/supervisor
owner is responsible for all accepted records and their **complete reachable
capture graph** while shutdown is uncertain. A consumer-owned TaskHandle
is **not** that owner. Only a proven join may transition to
`joinedStopped` and permit full cleanup. Simply maintaining
`_retained` inside an executor after shutdown failure does not prove
independent reachability if every caller abandons that executor; an
explicit independent root/lifecycle policy is required.

**Borrowed-family candidate:** never unwind an arbitrarily borrowed
caller-stack TaskRef after a native unproven worker lifetime. An
unqualified `@trusted` wrapper and a `stopped` flag do not establish
the required postcondition. P07's fail-stop is a bounded research fallback,
not adopted public API behavior.

**Still OPEN:** real native join failure / real post-launch start failure,
POSIX vs Windows/macOS failure policy, independent supervisor
implementation and abandonment, thread self-join/reentrancy, actual
GC-ownership proof for arbitrary closures, cancellation, general
`@safe TaskScope`, and fair native LDC performance.

**Disposition:** KEEP P20 as source-pinned real-M0 state evidence.
NO-GO for production code change or for calling a synthetic fault a real
OS failure/recovery. Maintain ADR-0001 **PROPOSED**, Issue #17 **OPEN**,
PR #38 **Draft**; preserve `develop`, `main`, M0 and unrelated PR #35.
