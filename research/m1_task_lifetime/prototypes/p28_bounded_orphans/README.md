# M1 P28 — Bounded orphan ownership and uncertain-shutdown capacity

**Date:** 2026-10-15. **Status:** executable **research policy**,
not adopted production API, not a native OS error-recovery strategy,
and not benchmark evidence.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

**Precedents:** [P20 false-stopped actual executor](../p20_owned_native_unknown/README.md),
[P21 shutdown proof model](../p21_shutdown_contract/README.md),
[P23 source-pinned real M0](../p23_real_owned_lifecycle/README.md),
[P24 process-rooted registry](../p24_durable_root/README.md),
[P25 owner families](../p25_owner_modes/README.md),
[P26 token/registry hazards](../p26_token_registry_safety/README.md),
[P27 application-exit counterexample](../p27_registry_transitions/README.md).

## Research question

Which *bounded* management and availability rules are compatible with
the previously qualified **native-join-first** release condition when
a controller abandons a real M0 executor? Does a shutdown-uncertain
executor still consume capacity? Can a supervisor drain multiple
independently owned tasks without touching the original M0 scheduler
or serializing every task's worker hot path?

The P28 experiment uses a fixed two-slot `BoundedOwner` anchored by a
module-lifetime class reference, plus explicit `GC.addRoot/removeRoot`
per admitted executor. It models a **management quota on concurrent
executor roots**, not a cap on individual admitted tasks, and
explicitly separates *normal orphan shutdown* from *native-uncertain
retention*.

[Source](../p11_real_pool/consumer/p28_bounded_orphans.d) ·
[Runner](../../../../tools/research/m1_p28_bounded_orphans.sh) ·
[P11 DUB fixture](../p11_real_pool/dub.sdl).

### Unmodified production source

- `owned_task.d`: pinned Git blob
  `e74d6a73f956c562eab176e27687a47249f5815d`, generated
  into the separate P23 **deferred-start research module**;
- `submission_pool.d`: pinned Git blob
  `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

The actual M0 `OwnedNode`, `TaskRef`, submission FIFO, work-stealing
deques, worker start/dispatch/steal/park, accepted/completed accounting,
and per-record post-dispatch reclamation are unchanged.

No files under production `source/`, `develop`, `main`, or other
workspace repositories are modified.

## Bounded owner policy under test

### Admission / quota

`enroll(executor)` accepts **only a constructed, never-started**
executor. Under the registry mutex it installs an explicit strong GC
root **before native launch**, occupies one fixed slot, and increments
`installed`. If both slots are occupied, it **refuses the third**
without registering or starting it, and increments `capacityDenied`.
The original proposed executor remains independently constructed.
No eviction, covert detach or out-of-quota launch is permitted.

### Explicit orphan handoff

`markAbandoned(slot)` is an **explicit management handoff**:
a normal active owner moves to `orphaned`; a
`shutdownUncertain` owner remains `uncertain` with abandonment
recorded. The state cannot be entered twice. The manager denies
further `activeBorrow` from an orphaned slot.

**Important limit:** the manager does NOT observe GC finalizers or
automatically detect that every external D reference was dropped.
Neither does it revoke caller-owned class references that escaped
before the handoff. A public API would need explicit leases /
capability checks if such escape must be prevented.

### Normal native shutdown

A `closeOrphan` call transitions exactly one eligible
`orphaned → draining`, executes the **actual M0**
`closeAndJoin()` and only then records `joined`. Multiple managed
executors may be closed by **different control threads**, while each
executor's M0 close remains single-owner. The supervisor itself
holds roots independently of any original submitter or `TaskHandle`.

`reclaim(slot)` requires `joined`, actual
`OwnedTaskExecutor.isStopped()` confirmed by successful native joins,
`accepted == completed` and `retained == 0`; it calls
`GC.removeRoot`, empties the slot and increments `removed`
**exactly once**. Only then is executor capacity reusable.

`cancelNeverStarted` is a distinct permitted release for
`reserved` owners with a true constructed/no-start proof.
It is forbidden after native launch, even if there were no tasks.

### Unknown native liveness

The original M0-owned reference cannot be freed based on
`shutdownUncertain`; the uncertain slot **still counts toward
capacity** and `closeOrphan`, `reclaim` and
`cancelNeverStarted` reject it. This conservative choice means
a permanently unprovable native join **can exhaust the manager
quota indefinitely**. It is a deliberate bounded-residency /
availability tradeoff, not a way to auto-recover native OS failures.

The test-only `finishKnownSynthetic` method is permitted **only**
for P23's failure injected *after a known successful pool launch*
and **before any actual native join call**. It performs the **first
real join** and releases the root only after that succeeds.
It never retries a failed `pthread_join`. A true native start/join
exception remains fail-stop in the source-pinned P23 variant.

### Process shutdown

P27 demonstrated that a `shared static ~this()` module destructor
may be unreachable before druntime waits for a live native worker.
P28 therefore exposes an **explicit application-close check**
performed **while `main()` is still running**. Any registered,
unjoined or unknown executor prints
`P28_APP_EXIT_UNFINISHED_FAILSTOP` and aborts. There is no
implicit detach, successful-shutdown claim or exception swallowing.

This is intentionally a **research fatal policy** rather than
a proposed universal consumer experience.

## Executable tests on actual M0 native threads

The source executes the following cases **six times per executable**:

| Case | Native M0 evidence |
|---|---|
| Bounded orphan drain | Two independently rooted one-worker M0 executors, each with an accepted blocked `Job` holding a nested GC graph. Third constructed executor refused at quota. Both submitter handles abandoned, explicit orphan handoff, four forced GC collections, two concurrent native joins, exact checksums and execution counts, then two root removals. Previously refused executor can then occupy a freed slot and be canceled as never-started. |
| Uncertain retains quota | A real M0 worker pool successfully launches before a **synthetic** post-start uncertainty marker. Its root and capacity remain occupied across GC collections. A second never-started owner occupies the other slot, a third is rejected; no premature reclaim/close or no-start cancellation of the unknown worker is allowed. Known synthetic recovery executes its **first real join**, then frees the slot. |
| Application-exit fail-stop (two separate native processes) | One process reaches explicit application shutdown with a **synthetic-uncertain** orphan; another with a **regular live** orphan. Both must print the specific marker and terminate with raw SIGABRT / exit **134**. These processes are not invoked inside the positive suite. |

The test's ledger totals, per executed positive binary:
`6 × (3 normal registrations + 2 uncertain registrations) =
30` explicit root installations, **30** matched removals;
`6 × (1 normal capacity rejection + 1 uncertain rejection) =
12` capacity refusals. No timings are claimed.

Expected positive marker:

```text
P28_BOUNDED_OWNER_PASS orphan_drains=6 unknown_retained=6 root_pairs=30 quota_denials=12
```

Expected negative marker:

```text
P28_APPLICATION_EXIT_FAILSTOP_PASS unknown=134 orphan=134
```

The [runner](../../../../tools/research/m1_p28_bounded_orphans.sh)
regenerates the exact source-pin P23 copy and removes it on exit,
uses bounded `dub run` under debug and whole `-release` for both
pinned compilers, adds LDC `-O3` without `-release`, and executes
negative builds directly to preserve real SIGABRT return codes.

**Source commit:** [`92acd8ec`](https://github.com/alex-1974/concurrency-d/commit/92acd8ec72f91a1e030388725f214a427aa188e8).
**Code CI:** [Actions #38736637631](https://github.com/alex-1974/concurrency-d/actions/runs/38736637631).
Verify the complete DMD/LDC run conclusion and final documentation
HEAD before declaring P28 green.

## P29 generation-tagged owner follow-up

[P29](../p29_generational_owner/README.md) qualifies a correction to
the P28 **bare-slot-index identity**: each reusable slot has a
monotonically increasing generation that is verified under the
same manager Mutex for every lifecycle and submission operation.
Stale pre-reuse handles are tested against a new, live actual-M0
executor under four simultaneous native attacker threads. In
addition, an unproven native-liveness slot remains occupied while
a separate certified never-started slot is recycled.

The two-element handle is **not** an unforgeable security token or
a general `@safe` ownership capability. The P29 registry also adds
lock/unlock operations around managed task submission, so its
throughput and contention overhead require real optimized XPS
measurement before any production decision.

## Decision status

**KEEP as research evidence:** bounded independent native ownership
can reject a third executor before launching it, preserve multiple
orphaned M0 task graphs through GC, drain and join them concurrently,
reclaim only after native proof, and keep unproved native liveness
charged to the owner budget. A once-per-owner management mutex is
not necessarily a per-task *worker hot-path* lock.

**NOT QUALIFIED:** automatic abandoned-handle detection; a
production-safe process-global manager; rich slot leases/capabilities;
uncertainty recovery after a true native join/start error; cross-platform
native shutdown; concurrent arbitrary register/start/abandon/close
races beyond the tested transitions; global control lock contention
or CPU overhead; general `@safe` borrowed or owned captures.
No numeric C++/LDC parity, throughput or allocation reduction
claim is supported.

**Next bounded decision:** owner capacity exhaustion policy,
explicit drain deadlines and application availability tradeoffs,
whether a registry is truly needed versus a caller-owned lifetime
token for each public use case, and a semantically matched
**optimized XPS** benchmark separating owner setup/teardown
from steady-state TaskRef throughput. Preserve the existing
M0 hot path as the baseline.

ADR-0001 stays **PROPOSED**; Issue #17 **OPEN**; PR #38
**DRAFT**. PR #35 is grandfathered and untouched. No merge.
