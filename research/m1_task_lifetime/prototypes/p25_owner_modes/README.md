# M1 P25 — Scoped LifetimeToken versus process-owned task registry

**Date:** 2026-10-15. **Status:** compiler-qualified **research comparison**,
not a public API choice, not a production promotion and **not** a
speed benchmark.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[PR #38 Draft](https://github.com/alex-1974/concurrency-d/pull/38).

**Precedents:** [P20 real M0 false stopped](../p20_owned_native_unknown/README.md),
[P21 shutdown state contract](../p21_shutdown_contract/README.md),
[P22 independent native owner](../p22_native_supervisor/README.md),
[P23 source-pinned actual M0 lifecycle](../p23_real_owned_lifecycle/README.md),
[P24 process-rooted registry](../p24_durable_root/README.md).

## Decision being investigated

P24 demonstrated a *process-reachable registry* with `GC.addRoot`
before native worker launch and `GC.removeRoot` only after proven
successful native join. This permits all submitter/controller handles to
disappear without losing the accepted TaskRef graph, but imposes
persistent global owner bookkeeping and shutdown obligations.

P25 compares that ownership family to an explicit **noncopyable lexical
`LifetimeToken`**, while holding the **same actual M0
`OwnedTaskExecutor` task and worker semantics**. The token acts as a
scoped controller: it cannot *successfully return from scope* with a
live registered executor. If the user forgets to close or a native join
cannot be proven, the experimental destructor **aborts** rather than
allowing a potentially live raw TaskRef owner to disappear.

**These families are not interchangeable**: a registry can support
owned work that outlives controller scopes, while a fail-stop token
requires strict lexical resource management and sacrifices availability
when its contract is violated. A borrowed TaskScope also requires a
separate static borrow-safety proof; P25 does not supply one.

## Unchanged underlying scheduler, exact evidence provenance

The [P25 consumer](../p11_real_pool/consumer/p25_ownership_modes.d)
and [DUB fixture](../p11_real_pool/dub.sdl) use the source-pinned
[P23 generated research copy](../../../../tools/research/m1_p23_make_owned.py)
of `OwnedTaskExecutor`, which performs **deferred native start** and
distinguishes `shutdownUncertain` from `joinedStopped`.
The actual M0 `SubmissionWorkerPool`, TaskRef FIFO, work-stealing
deques, OwnedNode, ResultCell and per-task execution/return accounting
are **unchanged**.

- Original `source/concurrency/internal/owned_task.d` Git blob:
  `e74d6a73f956c562eab176e27687a47249f5815d`.
- Original `source/concurrency/internal/submission_pool.d` Git blob:
  `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- Dependency remains `containers-d 0.2.0`.
- All changed files are under `research/`, `tools/research/`
  or the M1 research CI. No library production `source/` was modified.

### Mode A — lexical `LifetimeToken` (candidate)

P25 defines a deliberately small `struct LifetimeToken` with
`@disable this(this)` so ordinary copies cannot create duplicate
claimants to `GC.removeRoot`.

The token:
1. Explicitly adopts the **constructed but not started** research M0
   executor; calls `GC.addRoot` before starting native workers.
2. Allows controller operations through a borrowed executor handle.
   Ordinary submission/result handles may be discarded.
3. Rejects `tryRelease()` until P23's `isStopped()` means that an
   **actual native join succeeded** and all retained records were
   safely cleared. On success it unregisters the explicit root exactly
   once and invalidates its own reference.
4. Provides a `~this() @system nothrow` **fail-stop** when the lexical
   lifetime ends with an active registered root; it does **not** detach,
   silently leak or infer native quiescence from a shutdown request.

The destructor is a deliberately severe **research** policy. P25 does
not establish a user-friendly production exception API, runtime
recovery from failed `Thread.start()/join()`, or a generic D borrow
checker. The noncopyability gate tests ordinary postblit copying;
it does not certify every possible move, placement, lifetime or
cross-thread escape of a D struct. Such constraints require further
negative probes before any `@safe` API is exposed.

### Mode B — persistent registry (P24-like baseline)

P25's process-rooted `ProcessRegistry` also installs
`GC.addRoot` before native worker start and refuses early release.
Unlike the token, a module-lifetime registry retains the owner
**after local controller handles disappear**, allowing work to finish
without preserving the original lexical caller scope.

The process-level registry must subsequently arrange or explicitly
require native join/cleanup. Without that, an owner may remain rooted
indefinitely. This small experiment has a one-slot mutex-protected
registry and is not an accepted multi-tenant lifecycle manager;
[P24](../p24_durable_root/README.md) already tested independent
concurrent two-slot retention.

### Contract comparison (not performance results)

| Concern | Lexical token | Process-reachable registry |
|---|---|---|
| Installed before real M0 native start | Explicit `GC.addRoot` | Explicit `GC.addRoot` |
| Allows lexical caller to forget to join and return normally | **No**; research destructor fail-stop | **Yes**, root remains held |
| Native worker may still run after local controller handles disappear | Scope must still exist, otherwise fail-stop | Registry independently owns it |
| Proves `@safe` generic borrows/captures | **No** | **No** |
| Reclamation gate | Verified `joinedStopped` | Verified `joinedStopped` |
| Root/removal path | Token-local, no registry lookup | Shared registry lookup plus mutex |
| Risk if shutdown remains uncertain | Scope cannot complete normally; fatal policy | Potential unbounded retention / availability obligation |
| Suitable final API | **Not decided** | **Not decided** |

The token avoids a process-global registry lookup on its lifecycle
path, but **does not eliminate the original M0 admission locking,
scheduler costs or native joins**. The test intentionally has no
timing numbers: **no DMD/LDC/C++ performance claim follows** from
this structural comparison.

## Matched real-M0 experiment

[Runner](../../../../tools/research/m1_p25_owner_modes.sh):

```sh
bash tools/research/m1_p25_owner_modes.sh dmd
bash tools/research/m1_p25_owner_modes.sh ldc2
```

Each executable executes six repeated pairs per mode and outcome:
`6 × (token normal + registry normal + token injected uncertain +
registry injected uncertain)`, yielding **24 checked executions**,
12 per ownership mode, 12 normal and 12 injected uncertainty.

Both modes use the same one-worker real M0 pool, admission dimensions,
typed callable, two-level GC graph, single accepted task, caller/result
handle drop, native semaphore blocker, four forced GC collections per
blocked observation, exact `accepted/completed/retained` count oracle,
and checked result value. The uncertainty case additionally exercises
a **known synthetic error injected before any real native join**,
checks `shutdownUncertain` and denied release, then performs the **first
actual successful native join** before freeing the root. No real
failed OS join is simulated or retried.

Positive success marker:

```text
P25_OWNER_MODES_PASS token=12 registry=12 normal=12 uncertain=12
```

Independent negative gates:

- `--d-version=P25NegativeCopy` **must fail compilation** when
  attempting to copy a `LifetimeToken`. The runner requires a
  copy/postblit/disabled diagnostic, not just any compiler failure.
- `--d-version=P25DropFault` constructs a token, starts a real native
  worker without joining, then leaves its lexical scope. The destructor
  prints **`P25_TOKEN_DROP_FAILSTOP`** and calls `abort()`.
  The runner executes the built native binary directly (because DUB
  wraps abnormal child exit) and requires **exit 134** as well as the
  distinct marker, so an unrelated failure cannot pass this gate.

```text
P25_SCOPE_FAILSTOP_PASS disabled_copy=1 exit=134
```

DMD 2.111.0 and LDC 1.41.0 run the positive checks in both normal
debug and whole `-release` builds; LDC additionally runs debug
`-O3` with assertions enabled. Each subprocess has a timeout.
No speed ratios or C++ parity estimates are inferred from CI wall time.

**Executable code commit:**
[`401a2484b2573408d66bb4302992c6b7b13f7eab`](https://github.com/alex-1974/concurrency-d/commit/401a2484b2573408d66bb4302992c6b7b13f7eab).
**CI:** [Actions #38728232515](https://github.com/alex-1974/concurrency-d/actions/runs/38728232515):
P25 positive and negative steps passed on DMD/LDC. Check the
entire P01–P25 matrix separately before declaring final-HEAD green.

## P26 move and contention follow-up

[P26](../p26_token_registry_safety/README.md) qualifies the same
original-M0 owner-token/registry source under additional DMD/LDC
security and error-boundary gates: legal
[`std.algorithm.mutation.move`](https://dlang.org/library/std/algorithm/mutation/move.html)
of a token carrying an explicit GC root, compiler rejection of
copying a borrowed token by a ref-parameter return, ordinary exception
unwinding with successful native join in `finally`, fail-stop when
unwinding without native quiescence, and simultaneous registry lookups
and releases over a **fully joined** executor. The source P25 normal
and synthetic-fault gates remain in CI unchanged.

These are deliberately **bounded source-form and native scheduling
witnesses**. They do not establish a general `@safe` token escape
checker, safe concurrent release of an *active* worker, real native
join-error recovery, or a performance win for one owner model.

## Disposition and next gate

**KEEP research evidence; DEFER choice of one universal owner.**
Both modes meet the *bounded test* obligation of holding owned
GC task graphs until verified native quiescence. They provide
meaningfully different consumer semantics and neither alone is a
complete public executor model.

**Next (P26):** qualify explicit token placement/move/copy hazards,
exceptional unwind behavior and concurrent controller interference;
separately qualify registry thread-safe enrollment/release and
long-lived uncertain-shutdown capacity and cleanup policy. Only once
semantics are fixed should a release-mode native-XPS benchmark
measure per-owner registration/unregistration, startup, steady-state
task throughput and shutdown costs under **matched** workloads and
appropriate C++ comparison. The root mechanism should not impose
an extra lock or allocation on each task's worker hot path without
measurements proving it worthwhile.

**NO-GO:** automatic production `OwnedTaskExecutor` promotion,
arbitrary `@safe TaskScope`, generic callable ownership, real native
join-error recovery, cross-platform Windows/macOS error policy,
or merging Draft PR #38. ADR-0001 remains PROPOSED, Issue #17 OPEN;
preserve `develop`, `main`, M0 and grandfathered PR #35.
