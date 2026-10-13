# M1 P06 — Worker start/join/Error lifecycle and the quiescence boundary

**Status:** qualified narrow research scenarios, **NOT an accepted general safety proof**.  
**Date:** 2026-10-13  
**Issue:** [#17](https://github.com/alex-1974/concurrency-d/issues/17)  
**Branch / PR:** `research/m1-task-lifetime-boundaries`, [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38)  
**Parents:** [P04 typed scalar execution](../p04_value_only/README.md), [P05 trusted-boundary audit](../p05_trust_audit/README.md).

## Why the previous cleanup path was incomplete

P05's `WorkerBatch.closeAndJoin()` invoked the default `Thread.join()` on each worker sequentially. This is unsafe as a **general multi-worker join barrier** if a worker terminates with an unhandled `Throwable`: the default `join(rethrow = true)` can rethrow that worker's error **before later workers have been joined**. The function's caller then unwinds stack-resident `TaskRef` storage while other workers may still hold pointers to it.

The D druntime API explicitly documents `Thread.join(bool rethrow = true)` and that `join(false)` **returns** a worker's unhandled `Throwable` after joining. It also documents a separate `ThreadException` when the join operation itself fails. See the [official D druntime ThreadBase reference](https://dlang.org/phobos/core_thread_threadbase.html) and [Thread reference](https://dlang.org/phobos/core_thread_osthread.html). These pages document API intent; compiler-pinned runtime behavior is tested separately below.

These are three distinct events:

1. **Worker callback failure** — a worker throws an `Error` that reaches its thread entry; the OS thread terminates and can be joined; the original error should not hide unjoined sibling threads.
2. **Native join failure** — `Thread.join(false)` itself throws a `ThreadException`. The target thread's quiescence has **not** been established merely by catching that exception. A library returning to an owner of stack-borrowed records may cause a use-after-lifetime. **This remains an explicit NO-GO**.
3. **Thread creation failure** — `Thread.start()` can throw. We can test the cleanup after 0, 1, or 2 **successfully completed** starts; this does not prove what happens if native start has already launched a worker but throws before the caller can record it.

## Research changes

P06 extends the same standalone research module at `research/m1_task_lifetime/prototypes/p04_value_only/concurrency/research/m1_value_scope.d`. The M0 production `TaskRef` transport and its `dispatchTask` are compiled **unchanged**. P01–P05 evidence has not been replaced or backdated.

- Use `workers[i].join(false)` to **join every started worker first** and collect the **first unhandled worker Throwable**.
- After successful joins of *all* started workers, mark `joined = true`, then propagate the collected failure. Do not read scalar task results on failure.
- For successful runs (no worker failure), require `pending == 0` and `accepted == completed`.
- For worker-`Error` runs, do **not** equate accepted tasks or normal completion counters with quiescence. A task can abort before ordinary completion accounting, and an entire queue may remain unexecuted if its workers die. Thread joins, not completion counters, justify releasing the private record frame. Re-throw the worker Error rather than returning a successful `ScalarBatchResult`.
- Retain a `scope(exit)` completion-accounting attempt in the worker loop, but do **not** rely on this counter for lifetime safety after fatal Error unwinding; the initial Error experiment showed the counters were not an adequate completion predicate.
- Add test-only `version(M1P06Start)` hooks that fail before the next worker start after 0, 1, or 2 **successfully launched** threads. `start()` catches the ordinary injected Exception, calls `closeAndJoin()`, and rethrows only after the prior started threads join.
- Add test-only `version(M1P06Fatal)` hooks that produce an `AssertError` from the typed `@safe nothrow` task thunk for a sentinel `int.min` input. The fatal tests run as **separate timeout-bounded executables**, not as part of an unguarded consumer process.
- Test one failing worker, then both workers failing while **two queued tasks remain pending**. The latter must propagate an Error after joining both threads, not produce a successful result; a new independent batch then succeeds. Records are not reused before join.
- The tests keep the existing `@system` worker lifecycle and **`@trusted` dispatcher** research only; no compiler-proven general `@safe` borrowed dynamic task contract has been established.

## Reproduce

```bash
bash tools/research/m1_worker_lifecycle_probe.sh dmd
bash tools/research/m1_worker_lifecycle_probe.sh ldc2
```

Each runner uses the pinned compiler, `-preview=dip1000`, `-unittest -main`, and **a distinct binary** for `M1P06Start` and `M1P06Fatal`. The flag is compiler-specific: DMD `-version=...`, LDC `-d-version=...`. The fatal-worker process is bounded with `timeout --signal=TERM --kill-after=2s 20s` so a deadlock/abort cannot hang the entire workflow indefinitely.

The LDC runner additionally qualifies the same two variants with `-O3`, keeping assertions enabled (no `-release`). This is optimized **correctness**, not a throughput benchmark.

### Executed expected outcomes

| Scenario | Correct bounded expectation |
|---|---|
| Inject pre-start failure after 0 successful launches | no worker to join, error propagated |
| Inject after 1 successful launch | first worker receives close and is joined before error propagates |
| Inject after 2 successful launches | both workers receive close and are joined before error propagates |
| One `AssertError` in a worker | no successful batch return; both workers joined, Error propagated |
| Two worker `AssertError` values | both threads joined even though two unclaimed tasks remain queued; Error propagated, incomplete work not reported as success |
| New, healthy lexical batch after failed fatal batch | no stale active worker is left referring to old stack records in this tested configuration |
| All normal P04/P05 consumer paths | unchanged typed input snapshot and scalar results, previous positive and negative compiler gates preserved |

**No result from this table qualifies an actual failed OS thread join or a partially successful native `Thread.start()` that throws after OS launch.**

## Evidence and observed failure

The **initial P06 fatal probe failed under both pinned compilers** ([CI #38383612775](https://github.com/alex-1974/concurrency-d/actions/runs/38383612775)): although the worker Error was caught, the old success-only `accepted == completed` assertion failed during cleanup. The test process also emitted a follow-on `pthread_mutex_destroy` abort during cleanup after the unit test failed. This result was **not reclassified as a toolchain bug** and was not hidden; it proved that normal completion is not a valid terminal predicate for fatal-worker execution.

The source was corrected to distinguish successful task completion from **joined but failed/abandoned** execution. The same isolated tests then passed under both compilers ([CI #38383923253](https://github.com/alex-1974/concurrency-d/actions/runs/38383923253)). An additional stronger regression asserted that exactly two queued tasks remained unclaimed after both workers died, and [CI #38384177075](https://github.com/alex-1974/concurrency-d/actions/runs/38384177075) passed with DMD 2.111.0 and LDC 1.41.0.

Exact asserted-queue source commit: `4e367200017937e47788b3477f45161732704f33`. Later runner commit `469002a80436769af54205faa9310241b210c9e9` adds optimized LDC P06 checks without changing that implementation. **[GitHub Actions #38384303420](https://github.com/alex-1974/concurrency-d/actions/runs/38384303420) passed both jobs**: DMD 2.111.0 job `115252155169`, LDC 1.41.0 job `115252155473`. The LDC log explicitly confirms `M1P06Start` and `M1P06Fatal` PASS twice each, once normally and once with `-O3` and asserts enabled. Prior P01–P05 remained passing in the same workflow.

## Remaining safety decisions — intentional NO-GO

1. **A failing native `Thread.join(false)` is not an ordinary worker exception.** The current loop would still exit prematurely if this join throws, so worker accesses to scoped stack storage are no longer provably finished. We need an explicit policy: fail-stop before returning, a reliable lower-level join with proven cleanup, or a fundamentally different ownership/lifetime model. Retrying a failed native join without evidence is **not** a proof.
2. **Actual native start failure is not injected here.** The hook fails between normal starts; exact OS/druntime behavior if a launched-but-unreported thread exists is not established. Source-level/OS-specific qualification is required before a general public guarantee.
3. **Fatal errors are not normal recovery.** Handling an injected assert `Error` in a bounded Linux research executable does not promise safe recovery from corruption, OOM, platform process faults, `SIGSEGV`, arbitrary failure of the runtime itself, or untrusted user `@trusted` code.
4. **Worker Error with pending tasks is not successful completion.** The accepted-but-unexecuted jobs must be surfaced as aborted work by any real future API. Their capture storage may be released only after all native workers are quiescent. A production result/cancellation policy needs its own tests.
5. **No general dynamic borrowed `@safe TaskScope`.** This probe continues the scalar-only P04 family, deliberately excluding arbitrary closure captures, unsafe aliases, nested scopes and concurrent producers; P03 remains `@system`.
6. **No performance equivalence claim.** The test uses an isolated mutex FIFO and per-call native worker allocation; it does not measure a production scheduler, R0.5 independent owned-task latency, or benchmark any alternatives.

**Disposition:** KEEP as narrow research evidence and as a regression for the previously untested `Thread.join(rethrow)` distinction; **NO-GO** for promoting the broad parallel `@trusted` lifetime guarantee until native join/start exceptional paths have a verified fail-closed policy. ADR-0001 remains PROPOSED, Issue #17 remains OPEN, PR #38 remains DRAFT, and no production/source/CI changes were made outside the research branch.
