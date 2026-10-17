# M1 P23 — Real M0 OwnedTaskExecutor: prelaunch retention and honest shutdown

**Date:** 2026-10-15. **Status:** bounded research implementation,
no production merge and no generic `@safe` guarantee.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Precedents:** [P20 real-M0 false stopped state](../p20_owned_native_unknown/README.md),
[P21 finite shutdown contract](../p21_shutdown_contract/README.md),
[P22 real native independent supervisor](../p22_native_supervisor/README.md).

## Research question

P22 proved a separate owner with actual `core.thread.Thread` workers
but did not run the production work-stealing pool. P20 used the real
`OwnedTaskExecutor`, but its constructor had already launched native
workers **before** the external research supervisor acquired a strong root.

Can the **actual M0 task scheduler** retain its existing
`TaskRef`/admission/worker-steal/completion/reclamation mechanics while
isolating only native startup and shutdown control and ensuring a separate
strong owner exists *before* the native worker pool starts?

**Candidate tested in P23:** a byte-source-pinned research copy of
`OwnedTaskExecutor` constructed without threads. A supervisor retains it
before calling explicit `researchStart()`. Underlying
`SubmissionWorkerPool` is the unchanged real M0 implementation; this
is not another queue, task allocator or independent scheduler.

## Source provenance and transformation

- Original [`source/concurrency/internal/owned_task.d`](../../../../source/concurrency/internal/owned_task.d):
  pinned Git blob `e74d6a73f956c562eab176e27687a47249f5815d`.
- Actual [`source/concurrency/internal/submission_pool.d`](../../../../source/concurrency/internal/submission_pool.d):
  pinned Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- [Source-pinned generator](../../../../tools/research/m1_p23_make_owned.py)
  refuses original source drift, renames the generated module to
  `concurrency.research.m1_p23_owned`, and changes only the owner's
  construction/startup/shutdown lifecycle and research fault hooks.
- [Actual M0 consumer](../p11_real_pool/consumer/p23_lifecycle.d)
  is built through [the existing P11 research DUB package](../p11_real_pool/dub.sdl),
  which depends on the real root `concurrency-d` and
  `containers-d 0.2.0`. The generated module is temporary and removed
  by the P23 runner at exit. Neither generated source nor test hooks enter
  the shipping package.

**Unmodified mechanisms:** `OwnedNode!(F,R)`, result cell and
`TaskHandle`, `RetainedTask` root storage, normal record reaping on
the worker's post-dispatch release marker, M0 FIFO admission and
backpressure, TaskRef transport, native worker loop and work-stealing
deque, inbox `accepted/completed` accounting.

### Lifecycle adaptation

The research copy distinguishes:
`constructed → starting → running → draining → joinedStopped`;
`starting` or `draining` may instead become **`shutdownUncertain`**
on a known injected fault. It never presents `isStopped()` as true merely
because shutdown threw.

A controller creates the research-owned executor in `constructed` and
installs it in a **separate `Supervisor` instance before any
`Thread.start()`**. Only then may it invoke `researchStart()`, which
constructs the original M0 `SubmissionWorkerPool`.
Concurrent admission remains prohibited until `running`.
The superclass is not changed and `trySubmit` remains **`@system`**.

Only one closer may linearize `running → draining` and execute the
native join. Other concurrent closers wait on the existing Condition
while `draining`; all observe the same terminal outcome. A successful
real native join permits the existing retained-root cleanup and
`joinedStopped`. **A thrown native join is not a quiescence proof.**

**Exceptional safety limit:** an **actual** druntime native
`Thread.start()` failure during pool construction or an **actual**
native join failure is deliberately **fail-stop** in this research
variant (`abort()`), not treated as an ordinary recoverable
`shutdownUncertain` return. There is no independently certified
OS-thread quiescence/retry protocol. A general-purpose release library
must make a separate availability and fatal-error policy decision.

### Two *synthetic* fault controls

1. **Pre-native-join injection:** an elected closer pauses on a
   semaphore before calling the original `_pool.closeAndJoin()`.
   Two other closers must actually enter the `draining` wait path.
   The first closer then throws an injected Exception. All three
   observe that same synthetic error; the accepted record remains
   rooted, the worker is still blocked, `isStopped()` is false and
   `shutdownUncertain` is true.
2. **After-successful-pool-start injection:** the research owner
   constructs a real, fully started M0 pool, then records a synthetic
   startup failure *before* accepting work. No owner records are
   abandoned while the worker remains unjoined.

For **only these known synthetic paths**, the test-only
`researchJoinKnownSynthetic()` may subsequently perform the **first**
real `_pool.closeAndJoin()` call (and fail-stop if it now throws),
then release roots after real join success. **This is not a retry
of a failed `pthread_join`** and does not establish recoverability
from a true native start/join failure.

## Native integration tests

[Runner](../../../../tools/research/m1_p23_real_m0_lifecycle.sh):

```sh
bash tools/research/m1_p23_real_m0_lifecycle.sh dmd
bash tools/research/m1_p23_real_m0_lifecycle.sh ldc2
```

The test uses always-evaluated assertions/oracles rather than relying
on side effects inside D `assert` statements. Whole `-release` and
optimized LDC `-O3` are distinct gates. Every DUB executable runs under
a bounded timeout.

Per test binary, the controlled suites run six independent repetitions
of each family:

| Test family | Actual M0 evidence / control |
|---|---|
| Normal joined shutdown | `OwnedTaskExecutor` retains a nested GC payload in an accepted, blocked task. Three native closer threads return after exactly one elected join. Accept/completed/root counts and checksum agree; external supervisor then discards root. |
| Injected uncertain pre-join | Two additional close callers demonstrably wait while a third pauses before joining. They agree on the injected failure. Four forced GC collections occur after the submitting owner handle is dropped; a separate supervisor retains the executor and task graph. Real native join later permits reclamation. |
| Injected after-pool-start | The original native M0 worker pool has started successfully before a synthetic failure. Admission is closed and the independently held owner root cannot be released until subsequent actual join success. |
| Four producers race shutdown | Four producer threads each attempt up to 64 real `trySubmit` operations, while the controller closes the actual M0 pool. The test checks `acknowledged == accepted == completed`, late submission rejection, joined state and zero retained records. |

The positive exit marker is:
`P23_REAL_M0_LIFECYCLE_PASS normal=6 prejoin=6 poststart=6 producer=6`.

**Code source commit:** [`44f31f4a89f69b5cfaa54c6274520795854582cd`](https://github.com/alex-1974/concurrency-d/commit/44f31f4a89f69b5cfaa54c6274520795854582cd),
with source-pinned actual native join fail-stop
[`b2f165d1`](https://github.com/alex-1974/concurrency-d/commit/b2f165d1bce83a1aff4cb7676eb3bf15ef69d773).
[GitHub CI #38724765690](https://github.com/alex-1974/concurrency-d/actions/runs/38724765690)
runs pinned DMD 2.111.0 and LDC 1.41.0 through the new and
existing P01–P22 gates. **Confirm the exact run conclusion before
claiming overall PASS**.

## P24 durable-root follow-up

[P24](../p24_durable_root/README.md) tests the next ownership layer
**without replacing the real M0 scheduler**. A process-reachable,
two-slot registry calls `GC.addRoot` on the source-pinned P23
`OwnedTaskExecutor` *before native worker startup*, holds separate
task/root obligations after producer/controller abandonment, rejects
release during unproven shutdown, and pairs every removal with an
actual successful native join. It also isolates two simultaneous
executors so release of one joined owner cannot clear the other
blocked executor's root. This does **not** establish a general public
lifecycle manager, arbitrary `@safe` captures or native failure
recovery; the P23 fail-stop policy remains.

## Decision gates

**KEEP as research:** deferred native start with independent
prelaunch owner; honest `shutdownUncertain` vs native-`joinedStopped`
distinction; coherent concurrent closer behavior; actual M0
admission/TaskRef/reclamation accounting maintained in the probe.

**Still OPEN / NO-GO for release:** external `Supervisor` itself may be
lost if all roots are abandoned; this is **not a globally anchored,
self-owned native worker lifecycle**. D's conservative GC tests do
not prove exclusive/transitive ownership of arbitrary `F`. Native
startup post-launch failure remains an unresolved druntime contract;
no real native join failure is triggered or recovered. Generic
`@safe` borrowed/scope tasks, cancellation, cross-platform
Windows/macOS shutdown behavior and native LDC/C++-matched
performance have not been qualified.

Next gate: qualify a **durably independent lifecycle root** (or an
explicit bounded fail-stop policy), worker-originated Throwable vs native
join failure, record reclamation after normal individual return, and
semantically fair release-mode performance for a selected production
candidate. Avoid new public abstractions until that proof exists.

Preserve ADR-0001 **PROPOSED**, Issue #17 **OPEN**, Draft PR #38,
`develop`, `main`, and grandfathered PR #35 unchanged.
