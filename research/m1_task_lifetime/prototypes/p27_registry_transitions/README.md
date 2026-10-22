# M1 P27 — Real M0 transitions and process-exit ordering

**Date:** 2026-10-15. **Status:** executable, bounded **research**;
no public API or production promotion. **Issue:** [#17](https://github.com/alex-1974/concurrency-d/issues/17).
**ADR:** [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md).
**PR:** [#38 Draft](https://github.com/alex-1974/concurrency-d/pull/38).

**Prior evidence:** [P21 state contract](../p21_shutdown_contract/README.md),
[P23 source-pinned actual M0](../p23_real_owned_lifecycle/README.md),
[P24 durable GC root](../p24_durable_root/README.md),
[P25 lexical vs registry](../p25_owner_modes/README.md),
[P26 move/unwind/lookup races](../p26_token_registry_safety/README.md).

## Scope

P26's registry readers and releases raced only **after** native workers
had joined. P27 qualifies three transitions missing from that proof:
the full register/start/submit/close/release sequence, close while the
native worker startup is pending, and explicit cancel **before any
worker has started**. The diagnostic examines whether a D module
destructor can enforce a process-level fail-stop when live workers
prevent ordinary program shutdown.

P27 uses the source-pinned [P23 research clone](../../../../tools/research/m1_p23_make_owned.py)
of the real M0 `OwnedTaskExecutor`, not a separately reimplemented
scheduler. The actual `SubmissionWorkerPool`, TaskRef ownership,
worker queues, stealing, retention, producer admission, and
accepted/completed accounting remain unchanged.

Production source Git blob pins:

- `owned_task.d`: `e74d6a73f956c562eab176e27687a47249f5815d`;
- `submission_pool.d`: `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

The source, tests and DUB configuration are **research-only**:
[`p27_registry_transitions.d`](../p11_real_pool/consumer/p27_registry_transitions.d),
[`m1_p27_registry_transitions.sh`](../../../../tools/research/m1_p27_registry_transitions.sh),
[existing P11 DUB fixture](../p11_real_pool/dub.sdl). No shipping
`source/` files, public APIs, released artifacts, or other repositories
are changed.

## Bounded owner model

The research `ManagedOwner` is a single-slot, process-anchored
registry with a Mutex, Condition, explicit
`GC.addRoot/removeRoot` and `activeCalls` counter. Its phases:

```text
empty → registered → starting → running → draining → joined → released
             └─────────────────────────────→ released (certified never started)
```

- `adopt()` requires an **unstarted** P23 executor and installs a
  strong GC root before worker launch. A module-lifetime reference
  anchors the controller independently of producer handles.
- `start()` claims the startup state under the registry Mutex. A
  second start returns false. A test-only semaphore can hold this
  phase **before** calling the actual M0 worker constructor.
- `tryPublish()` acquires an operation claim and a local owner
  reference under the registry Mutex, then uses the **actual M0**
  `trySubmit` outside the registry lock. The original M0 admission
  Mutex arbitrates publication vs close. Completion of the
  operation decrements `activeCalls`; this is a lifecycle-level
  counter, **not per-task worker-hot-path instrumentation**.
- `closeAndJoin()` waits for native startup to leave `starting`;
  exactly one controller claims `draining` and performs the real
  M0 join, while other close callers wait for the same outcome.
  A truly failed native join remains **fail-stop**, not recoverable.
- `tryRelease()` is forbidden unless `joined`, there are no
  outstanding caller operations, the actual worker join proved
  completion, `accepted==completed`, and all retained roots are
  cleared. The actual GC root is removed exactly once.
- `cancelNeverStarted()` is a *different terminal operation* that
  removes a root only while the source-pinned original M0 has
  demonstrably **never started**. It cannot run in `starting` or
  after `running`.

A class reference taken by an in-flight operation remains a local GC
reference even if `tryRelease` becomes eligible; the explicit count
prevents registry release before that operation has returned. This
does not prove arbitrary borrowed caller stack frames are safe.

## Positive real-native scenarios

Each build repeats **12 iterations** of each:

| Scenario | Witness |
|---|---|
| Producer vs shutdown | Two native M0 workers, four producer threads (up to 128 attempts each), three close callers. Only one join-owner. Acknowledged admissions equal actual M0 `accepted==completed` count, final retained roots zero, late admission rejected, and registered root removed once. |
| Start vs shutdown | One starter holds a test-only semaphore before native launch. A second `start`, premature `tryPublish`, `tryRelease` and no-start cancellation all fail. **Three closers demonstrably wait** in `starting`; after gate release, the real native pool starts and all three closers finish. One startup and one native join are claimed. |
| Certified no-start cancellation | Admitted/rooted P23 executor remains in `constructed` without native threads or tasks. Explicit cancellation can remove its GC root; subsequent start/cancel/release are rejected. |

Each also calls `GC.collect()` after the terminal state to exercise
the retained GC ownership graph; GC collection is conservative and
**not an independent soundness proof**.

Positive output:

```
P27_LIFECYCLE_RACES_PASS producer_close=12 start_close=12 never_started=12
```

DMD 2.111.0 and LDC 1.41.0 compile/execute normal debug and whole
`-release`; LDC separately executes debug `-O3`.

## Process-exit counterexample and corrected failure policy

**Important P27 finding (source evidence):**
The **first** [P27 CI run #38734363064](https://github.com/alex-1974/concurrency-d/actions/runs/38734363064)
completed all three positive test scenarios on **both** pinned
compilers, but its initial assertion that `shared static ~this()`
would run promptly with a still-active native M0 worker was
**falsified**. Both executions timed out after 40 seconds (exit
124), without the expected destructor diagnostic.

This is consistent with the D runtime attempting to wait for
registered threads *before* dispatching module destructors.
The timeout alone does not fully prove the exact druntime ordering:
a deeper pinned druntime source trace would be needed to establish
precisely where shutdown blocked. **The observable failure is
sufficient to reject a module-destructor-only fail-stop guarantee.**

P27 now distinguishes three separate process-boundary tests:

1. **`P27ExitActive`** runs an **explicit application-controlled
   shutdown check while `main()` is still executing**. If a native
   worker is still owned, it prints `P27_APPLICATION_EXIT_FAILSTOP`
   and calls `abort()`. The native test harness expects exit
   **134**, never a misleading clean return.
2. **`P27ExitUnstarted`** registers an executor but does not launch
   a native worker or explicitly remove the registration. It
   checks the `shared static ~this()` module-destructor sentinel
   as a limited no-worker control and expects
   `P27_PROCESS_EXIT_FAILSTOP`, exit **134**.
3. **`P27RuntimeOnly`** launches an M0 worker and deliberately
   omits the explicit application-level shutdown check. A
   five-second bounded diagnostic distinguishes an
   *unreached* module destructor (timeout **124** with no
   destructor marker) from a *reached* destructor (exit
   **134** with the marker). Either observation is reported
   explicitly; a silent clean exit or unrelated process failure
   is rejected.

These results cannot establish process-level failure recovery.
Production would need an explicit application-managed lifecycle
boundary plus a decision for deliberate process termination,
independent native supervision or permanently retained uncertain
work. A shutdown destructor is **not** evidence that borrowed
TaskRef referents will remain valid if the runtime deadlocks before
reaching it.

Expected gate markers:

```text
P27_EXPLICIT_EXIT_FAILSTOP_PASS active=134 unstarted=134
P27_RUNTIME_ONLY_BLOCKED_DIAGNOSTIC_PASS timed_out=124
```

The second marker records the **observed pinned-runtime behavior**;
the runner can instead report
`P27_RUNTIME_ONLY_DESTRUCTOR_REACHED_PASS exit=134` if
a future runtime reaches the module destructor successfully.

## Qualification and open issues

Reproduce:

```sh
bash tools/research/m1_p27_registry_transitions.sh dmd
bash tools/research/m1_p27_registry_transitions.sh ldc2
```

The bounded runner pins original source hashes, cleans the generated
P23 research copy on exit, and runs abnormal-process tests as
**separate native binaries** because DUB wraps SIGABRT exit codes.
No performance numbers are collected from CI wall time.

**Corrected executable source:**
[`f0e62d52`](https://github.com/alex-1974/concurrency-d/commit/f0e62d52815ca01dda02018ce878a5cd583339d2).  
**CI:** [Actions #38734779868](https://github.com/alex-1974/concurrency-d/actions/runs/38734779868).
Check the exact compiler matrix and later documentation HEAD before
claiming completion.

**KEEP as research**: prelaunch root registration; real M0 admission
against close; single join owner; operation and root release ordering;
separate never-started cancellation; **explicit** pre-runtime process
shutdown boundary. **NO-GO**: module-destructor-only rescue of live
workers, automatic native join retry, arbitrary `@safe` captures,
generic scoped-borrow unwinding, unbounded orphaned tasks, cross-platform
native shutdown contracts, and production adoption without matched
release-mode performance evidence.

## P28 bounded owner follow-up

[P28](../p28_bounded_orphans/README.md) turns the P27
application-close finding into a **two-executor fixed-capacity
managed-owner experiment** on the same source-pinned real M0 pool.
It tests explicit orphan handoff, concurrent *supervisor-driven*
native joins, non-evictable uncertain worker obligations, budget
rejection before worker launch, slot reuse after successful join
or certified never-started cancellation, and two direct native
application-exit fail-stop cases. No automatic GC-finalizer orphan
detection, native join-error retry or performance claim follows.

**Next gate** should consider the availability and root-capacity
policy for real abandoned owners (including shutdown orchestration
and bounded resource usage), plus matched optimized XPS throughput
for the actual ownership shape. Keep Issue #17 OPEN,
ADR-0001 PROPOSED, PR #38 Draft, and unrelated PR #35 untouched.
