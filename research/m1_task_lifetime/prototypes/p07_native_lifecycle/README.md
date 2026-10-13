# M1 P07 — Tagged druntime source audit and fail-closed worker-lifecycle research

**Date:** 2026-10-13
**Branch:** `research/m1-task-lifetime-boundaries`
**Issue:** [#17](https://github.com/alex-1974/concurrency-d/issues/17)
**PR:** [Draft #38](https://github.com/alex-1974/concurrency-d/pull/38)
**Status:** qualified **source findings** and bounded **simulated fail-stop probes**; **NO-GO** for public `@safe` scoped-borrow execution or general production approval.

P07 continues [P06](../p06_worker_lifecycle/README.md) and the [P05 trust audit](../p05_trust_audit/README.md) without resetting their earlier results. The real M0 task transport is compiled unchanged. All P07 code is conditional research code inside the existing P04 value-scope kernel, not a public release API.

## Source provenance (pinned exact repositories/tags)

Analyzed the **tagged source** of the toolchain versions qualified in this workspace:

| Toolchain | Runtime source / content SHA | Relevant lines |
|---|---|---|
| DMD **2.111.0** | [`dlang/dmd@v2.111.0`, `druntime/src/core/thread/osthread.d`](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/osthread.d), blob `8406458dd042f6979287b7c9aae8f26077912305` | [`Thread.start()` L403–509](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/osthread.d#L403-L509); [`join(bool)` L512–558](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/osthread.d#L512-L558); [destructor L292–311](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/osthread.d#L292-L311) |
| LDC **1.41.0** | [`ldc-developers/ldc@v1.41.0`, `runtime/druntime/src/core/thread/osthread.d`](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/osthread.d), blob `498961560d8032a2c1bb8444f9e7b882da2ef4ca` | [`start()` L446–583](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/osthread.d#L446-L583); [`join(bool)` L585–631](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/osthread.d#L585-L631); [destructor L319–350](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/osthread.d#L319-L350) |

**Provenance limit:** those files are the tagged source corresponding to the pinned versions; this analysis has not independently compared every file to the installed CI archive's bundled druntime binaries. CI compiles and executes tests using its pinned compiler selection.

## Verified source behavior (Ubuntu/Linux x86_64 POSIX path)

### 1. Native join and worker Throwable are distinct

Both implementations' POSIX `Thread.join(rethrow)` use:

```d
if (m_addr != m_addr.init && pthread_join(m_addr, null) != 0)
    throw new ThreadException("Unable to join thread");
m_addr = m_addr.init;
if (m_unhandled) {
    if (rethrow)
        throw m_unhandled;
    return m_unhandled;
}
```

Therefore:

- `join(false)` *defers the **worker's unhandled Throwable***, but does **not** suppress a **native join failure**.
- On a native failure, the code throws **before clearing `m_addr`**. The task record's safe destruction is not established by the failed call.
- The `Thread` destructor will **`pthread_detach`** a still-registered POSIX thread (subject to LDC's main-thread exception). Destruction/detachment is **not** a join or a lifetime fence and does not keep stack records valid until worker exit.
- The ordinary P06 `join(false)` loop therefore remains **unsafe as an unconditional trusted borrower-frame exit guard** if a native join throws and the caller can unwind.

Linux `pthread_join(3)` documents `EDEADLK`, `EINVAL` and `ESRCH` among possible errors: [man7 Linux manual](https://man7.org/linux/man-pages/man3/pthread_join.3.html). A **successful** join is a completion/lifetime barrier; an error code is not. POSIX `pthread_join(3p)` makes self-join/invalid thread semantics especially delicate; P07 **does not deliberately call pthread_join on itself or an invalid handle**, because that would not qualify a library contract on defined behavior: [POSIX reference](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/functions/pthread_join.html).

### 2. A `start()` exception is not always an unstarted worker

On the Linux POSIX path:

- DMD first calls `pthread_create(&m_addr,...)` (success means the OS thread has started), then **checks `pthread_attr_destroy`**. If the later call fails, `onThreadError` causes `start()` to throw *after the native thread may exist*, but the caller's `started++` has not run.
- LDC does likewise, with a larger shared-library `pinLoadedLibraries` handoff. Its tagged implementation checks `pthread_attr_destroy` after `pthread_create` as well.
- For Darwin the tagged implementations also check `pthread_mach_thread_np` after native thread creation; the failure interpretation is not qualified on macOS by this Linux-only research.
- **Important D-specific correction:** although `Thread.start()` is declared `nothrow`, its internal `onThreadError` routine throws a preallocated **`ThreadError : Error`**, not the `ThreadException : Exception` used by native `join(false)` errors. This is explicit in [DMD `threadbase.d` L40–70 and L1164–1181](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/threadbase.d#L1164-L1181) and [LDC `threadbase.d` L1237–1254](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/threadbase.d#L1237-L1254). A start cleanup guard limited to `catch(Exception)` is therefore **incorrect**. The P07 fallback intercepts `Throwable`, and the isolated start-failure simulation is typed as `ThreadError`.
- Linux's manual says `pthread_attr_destroy` normally succeeds on Linux; this is therefore a **source-level error path**, not evidence that it occurs in everyday Ubuntu execution: [Linux pthread attributes manual](https://man7.org/linux/man-pages/man3/pthread_attr_destroy.3.html). Portability and exceptional reliability still demand a policy.

A producer recording `started` **only when `start()` returns** can miss a possibly launched native worker on that path. Retrying startup or unwinding without an independently established worker/engine ownership state is not an acceptable proof for pinned caller-frame records.

### 3. `@trusted` cannot establish a postcondition just by catching

A broad `@trusted` wrapper that invokes an `@system` native lifecycle still has to prove: **no borrowed stack frame exits while any worker can hold a TaskRef to it**. On a native join failure or an ambiguous start failure, that postcondition is not established by the current runtime API. Simply treating the failure as a recoverable `Exception` would leak a possibly active pointer across the scope boundary.

## P07 conservative policy experiment (not production)

Under the conditional research flag **`M1P07FailStop`**, the existing P04/P05/P06 worker kernel is altered only for exceptional native-boundary returns:

1. In `WorkerBatch.start()`, **any** thrown `Throwable` is treated conservatively as potentially post-native-launch. It calls the C `abort()` fail-stop path rather than allowing a scope frame to unwind with unknown worker liveness. This intentionally gives up availability even for clearly pre-launch failures; it is a baseline safety fallback, **not** an ergonomic final policy.
2. In `WorkerBatch.closeAndJoin()`, **any thrown `Throwable` from a `join(false)` call** triggers the same fail-stop. By contrast, an unhandled worker `Throwable` *returned by a successful `join(false)`* remains P06 behavior: join all workers, then propagate the worker error.
3. The caller receives no successful result and cannot unwind a borrowed scope in either uncertain-native-lifecycle case: the process terminates via `abort`. This is only a correctness-of-process-termination argument **in the experiment's Linux environment**, not a portable memory-safety proof or acceptable general-purpose library UX.

Conditional fault hooks:

- `M1P07StartFault` deliberately throws a **`ThreadError`** **after** a successful native `worker.start()` but **before** the local `started++`. This models the missing-registration window; it does **not** claim to reproduce a real `pthread_attr_destroy` fault.
- `M1P07JoinFault` throws a simulated `ThreadException` at the join call site while workers have started. It tests the fail-stop path **without performing an invalid, undefined or corrupted native pthread operation**.
- The normal `M1P07FailStop` build with **neither** injection flag must still execute the real P04 `@safe` scalar consumer correctly.

Each injected case runs in a separate, timeout-bounded subprocess. The runner requires exit status **134** (`SIGABRT`) **and** a distinct `P07_FAILSTOP_START` or `P07_FAILSTOP_JOIN` marker, so an unrelated assertion or timeout does **not** count as success. The script disables core dumps. The P06 real worker-Error regression remains in the usual CI gate.

## Evidence and reproduction

From repository root:

```sh
bash tools/research/m1_native_lifecycle_failstop.sh dmd
bash tools/research/m1_native_lifecycle_failstop.sh ldc2
```

The original P07 executable source commit with passing normal and simulated fail-stop tests was `e23c49a1d4e5d8fe17458e00dfe28ddddb44e9f3`, with [GitHub Actions #38390259078](https://github.com/alex-1974/concurrency-d/actions/runs/38390259078) **PASS** for both DMD 2.111.0 and LDC 1.41.0. Job DMD `115272026340`, LDC `115272025864`.

LDC `-O3` simulated fail-stop checks were added to the same runner (with **assertions enabled**, not `-release`).

**Final P07 source/CI evidence (including the correct D runtime `ThreadError` start-failure simulation):**
- Implementation source commit: `a9562a5dd491a0a1db9b80c019a459f4211a6665`.
- [GitHub Actions **#38390697965**](https://github.com/alex-1974/concurrency-d/actions/runs/38390697965): both matrix jobs **PASS**, DMD 2.111.0 job `115273475082` and LDC 1.41.0 job `115273474637`.
- Each job checks the normal `@safe` external scalar consumer in the fail-stop version, plus both separate synthetic-fault subprocesses, each required to terminate via the expected distinct marker and SIGABRT (134).
- LDC separately checks **both** synthetic-fault branches under **`-O3`** with assertions enabled. P01–P06 and the old compile-negative probes remain passing under the same workflow.
- These results prove the injected **fallback** behavior, not that a real failed native join/start has been reproduced or that default production code is protected.

## Design disposition

| Potential response to native lifecycle failure | Scoped borrowed stack records | Independent owned tasks | Decision |
|---|---|---|---|
| Throw and unwind the scope after failed join | Potential live raw TaskRefs to expired stack storage | May survive if executor still owns/roots everything | **REJECT** for borrowed scope |
| Retry an unknown failing join | No guaranteed successful termination, may deadlock or violate OS preconditions | Same native lifecycle uncertainty remains | **NOT QUALIFIED** |
| Detach/drop Thread object | Detach does not wait, stack data can expire | Only if separately proven owned retention and worker completion | **REJECT** as borrowed-scope recovery |
| Fail-stop before frame unwind | Process terminates; no later use of invalid caller stack in normal process continuation | Not necessarily needed; availability loss | **RESEARCH fallback only** |
| Preserve tasks/closures under executor-controlled ownership | Cannot preserve arbitrary caller stack borrows without changing semantics | Matches independent owned task-family intent | **Prefer as separate owned-task design** |
| Independently proven native thread lifecycle and join protocol | Could support a guarded scope with carefully constrained borrows | Also useful for owned executor shutdown | **OPEN research gate** |

**P07 result:** The tagged implementation evidence confirms an *actual design hole* in the unrestricted `@trusted` worker-lifetime claim when start/join itself fails. The research fail-stop experiment demonstrates that a narrowly defined process-termination fallback can prevent *ordinary* scope unwinding under **simulated** failures; it does **not** repair/native-test those system failures or certify safe general concurrent borrowed tasks.

**Next action:** Decide whether the library should explicitly document native join/start failure as **fatal at the borrowed-scope safety boundary**, or whether general-purpose APIs should prioritize **independently owned** task-record/capture lifetimes with deferred executor shutdown. This decision must occur before accepting a public `@safe` TaskScope; assess POSIX/Windows/Mac differences and the user's availability requirements separately. Keep ADR-0001 **PROPOSED**, issue #17 **OPEN**, Draft PR #38 **DRAFT**, `develop` untouched, and preserve R0.5 PR #35.
