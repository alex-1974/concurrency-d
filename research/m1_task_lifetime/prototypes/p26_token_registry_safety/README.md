# M1 P26 — Move, exceptional unwind, and concurrent registry boundary

**Date:** 2026-10-15. **Status:** research-only, source-pinned native-M0
lifetime qualification, **not** an adopted public API, fully general
thread-safety proof, or native OS error recovery.

Tracking: [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

Precedent: [P23 real-M0 deferred start](../p23_real_owned_lifecycle/README.md),
[P24 process root](../p24_durable_root/README.md),
[P25 paired token/registry](../p25_owner_modes/README.md).

## Question / why P25 was not enough

P25 proved that an ordinary postblit copy of a noncopyable
`LifetimeToken` is compile-rejected, that ordinary joined shutdown
releases one token-root exactly once, and that dropping an active
token executes an intentional abort. It did **not** check that:

- an **explicit D move** transfers token ownership without leaving the
  moved-from value able to remove the root (or incorrectly abort);
- returning a **borrowed ref-parameter lvalue** by value cannot sidestep
  the copy guard;
- an ordinary **exceptional unwind** after real native join can exit
  safely with the original exception, but unwind *before* join cannot;
- an independently owned executor's registry remains internally
  consistent when multiple native threads race lookup against root
  release.

P26 adds those questions as separate research/versioned gates in the
[P25 original consumer](../p11_real_pool/consumer/p25_ownership_modes.d),
not as a new task scheduler or a production API.

## Exact production isolation

The unchanged M0 `SubmissionWorkerPool` implements actual
TaskRef queues, work stealing, native druntime `Thread.start`/
`Thread.join`, accepted/completed accounting and completion hooks.
Original source blobs:

- `source/concurrency/internal/owned_task.d`:
  `e74d6a73f956c562eab176e27687a47249f5815d`;
- `source/concurrency/internal/submission_pool.d`:
  `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

The existing [P23 source-pin generator](../../../../tools/research/m1_p23_make_owned.py)
creates a temporary, separate research owner module, which delays
native launch until a controller has installed its root. The existing
P25 `LifetimeToken` and `ProcessRegistry` both use explicit
`GC.addRoot` before the launch boundary and `GC.removeRoot` only
after native join is **proven**, and reject release otherwise.
The P26 runner removes the generated research module on exit.

## Positive proof gates

**P26Positive** executes the original P25 actual-M0 workload *and*
additional bounded cases, on DMD 2.111.0 and LDC 1.41.0:

| Case | Repetitions per executable | Checked boundary |
|---|---:|---|
| Explicit `move(initial)` of an actively registered token | 12 | New token retains one existing owner; actual native join succeeds; explicit root removed only once; both lexical destructors finish normally. |
| Ordinary `Exception` thrown while a registered token owns native workers | 12 | `finally` executes real `closeAndJoin()` and unregisters GC root before unwinding; original exception is preserved/caught; destructor does **not** abort. |
| Concurrent registry `tryBorrow` vs `tryRelease` | 12 groups | Each group has a real M0 owner with **completed native joins** and four reader/four release threads. A shared Mutex serializes lookup/root removal; exactly **one** releaser succeeds and registry ends empty; readers may see owner or null, and any seen owner must already be joined with zero retained records. |

This is a **bounded contention witness**, not evidence that a registry
can release a worker which is still active, or that arbitrary
borrowed references remain valid independently of all GC roots. The
returned D class reference is also held in a local native thread
activation while inspected. A future public API must specify
`lease`/borrow lifetime, permissible concurrent method calls, GC
safepoints and process teardown.

Positive marker:

```
P26_OWNERSHIP_SAFETY_PASS moved=12 unwind=12 races=12
```

P25's independent positive marker must still be present:

```
P25_OWNER_MODES_PASS token=12 registry=12 normal=12 uncertain=12
```

## Separate compile and fatal gates

**P26ReturnCopy** intentionally tries:

```d
LifetimeToken invalid(ref LifetimeToken borrowed)
{
    return borrowed;  // an lvalue copy, NOT explicit move
}
```

DMD/LDC must reject it with a copy/postblit/disabled diagnostic.
That establishes this one forbidden D source form, **not** an
exhaustive proof that all possible token escapes or
`@system` pointer casts are prevented.

**P26UnwindFault** constructs and starts a real M0 executor with
an explicitly registered token, then throws while the token's
scope is still active *without joining native workers*. The
token's existing P25 destructor prints
`P25_TOKEN_DROP_FAILSTOP` and terminates with `SIGABRT`.
The test also prints the distinct
`P26_INJECTED_UNWIND` marker before throwing; the test runner
requires **both** markers and raw native exit code **134**.
An unrelated exception or compiler failure cannot pass this gate.

These are research fail-stop semantics, **not** evidence that abort
is desirable for every consumer or supported target platform.

## Reproduce and CI

```sh
bash tools/research/m1_p26_token_registry.sh dmd
bash tools/research/m1_p26_token_registry.sh ldc2
```

The [runner](../../../../tools/research/m1_p26_token_registry.sh)
builds and runs debug and whole `-release`, plus LDC debug
`-O3` retaining assertions. Negative compile and expected abort
run separately; the test executable is invoked **directly** for
the fatal gate because `dub run` wraps abnormal child exit codes.

**Corrected executable source commit:**
[`a69c2334`](https://github.com/alex-1974/concurrency-d/commit/a69c2334c10fa39c4a95ea5fccf1924ebbe52266).
**Code CI:** [full M1 workflow #38730082266 — SUCCESS](https://github.com/alex-1974/concurrency-d/actions/runs/38730082266).
Both DMD 2.111.0 and LDC 1.41.0 passed the existing P25 and
new P26 steps, and the entire source-head M1 CI completed successfully.
The first runner attempt had a D-language syntax error (a `catch`
inside `finally`); it was corrected in the cited source commit
without changing the ownership invariants. Verify the documentation
HEAD separately before declaring the entire branch green.
Do not derive throughput or overhead measurements from shared-runner
CI timing.

## P27 process-exit follow-up

[P27](../p27_registry_transitions/README.md) qualifies
`register → start → publish → close → release` overlap on the
**real unchanged M0 worker pool**, the competing-start/closer barrier,
and a separate certified never-started root cancellation. Its first
native teardown probe exposed a crucial **negative result**:
with a still-active druntime Thread on pinned DMD/LDC Linux, ordinary
program return did not reach the module destructor before the
timeout. The revised gate therefore tests an **explicit
application-shutdown** fail-stop while `main()` is still executing,
and retains the runtime-only timeout as a diagnostic counterexample.
This does not qualify native join-error retry or any arbitrary
`@safe` scoped borrow.

## Assessment and remaining limits

**Keep as evidence, do not promote one universal owner.** The move
and unwind probes exercise only specific D source forms and error
paths. A move is not a proof of safely escaping all lifetimes.
A generic `@safe TaskScope` would additionally require proof that
arbitrarily borrowed caller frames cannot unwind before successful
native quiescence. P07's native start/join failure analysis and
the P23 source-copy fail-stop limitation still govern.

Registry contention tests isolate completed executors; a
production registry additionally requires adversarial overlap
between *new registration*, *native start*, *producer admission*,
*shutdown*, *lease acquisition and release*, *reentrant callbacks*
and *GC collection* with a validated lock-order policy. Lifetime
tokens additionally require negative probes for placement, address
escape, assignment/move in containers, double adoption and
destruction during exception handling.

There is no claim that P26 qualifies Windows/macOS or real
`pthread_join` failures. P26 is a correctness/semantic research
gate only; no native XPS performance result, CPU calibration,
tail latency, allocation profile or C++ parity claim exists.

**Next bounded gate:** develop an ownership policy matrix for
`owned`/scoped/independently managed tasks with a documented
process-teardown and abandonment contract. Qualify registration
contention and lifetime-token escape paths before considering
promotion. Only then run matched release-mode XPS benchmarks that
measure owner creation/teardown separately from the steady-state
task hot path.

Retain [ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md)
PROPOSED, Issue #17 OPEN, PR #38 Draft and unrelated Draft PR #35
unchanged. Do not change `source/`, `develop`, `main` or other
workspace repositories.
