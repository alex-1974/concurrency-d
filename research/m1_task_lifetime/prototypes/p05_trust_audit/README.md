# M1 P05 — `@trusted` audit and bounded lifetime-failure qualification

**Date:** 2026-10-13  
**Issue:** [#17](https://github.com/alex-1974/concurrency-d/issues/17)  
**Status:** **PASS** for the limited executed checks; **NO-GO** for certifying P04's parallel `@trusted` worker lifecycle as production-ready or for generalizing it to borrowing `TaskScope`.  
**Parent:** [P04 constrained value-only research](../p04_value_only/README.md).  
**PR:** [Draft #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Review scope and engineering contract

Read the repository's `AGENTS.md` and the canonical workspace `DESIGN_PRINCIPLES.md`, `DLANG_PRACTICES.md`, `QUALITY_GATES.md`, `GIT_GITHUB_WORKFLOW.md`. The workspace requires small auditable unsafe transitions; a compiler rejection of an `@safe` substitution is only **evidence that a trust annotation is required**, never evidence that `@trusted` is sound.

P04's only externally reachable test interface is:

```d
alias ScalarOperation = int function(int) @safe pure nothrow @nogc;

ScalarBatchResult evaluateScalars(
    scope const(int)[] inputs,
    ScalarOperation operation) @safe;
```

It snapshots at most eight integer values **before** any worker starts; no user-owned pointer or captured `delegate` crosses the worker queue. This is a **separate constrained value-task family**, not a generic scoped-borrow family.

## P05 source changes

The existing P04 implementation remains at the same research path; its historic P04 source SHA/CI evidence remains fixed as recorded in the P04 README.

1. **Compiler-checked `Record.prepare`:** changed from `@system` to `@safe` because this initialization copies scalar values, stores the typed function pointer, and assigns the thunk without an unsafe operation. Both pinned compilers now check this initialization.
2. **Zero/singleton bypass:** after the same explicit capacity/null validation and caller-side scalar snapshot, count 0 returns directly and count 1 computes `operation(snapshot[0])` inside the externally `@safe` function. No Thread, Condition, TaskRef, cast or `@trusted` call occurs in these two paths. This reduces actual exposure to the trusted parallel branch; no throughput or latency improvement is claimed without native measurement.
3. **Defensive validation at the trusted entry:** `executeCopied` rejects `count < 2`, `count > ValueCapacity` or a null operation **before preparing any record or creating a worker**. The safe caller had already checked this, but it is not acceptable for a trusted primitive's memory safety to hinge solely on the discipline of another same-module caller.
4. **Negative substitution challenges:** the test runner alters one trust marker at a time to `@safe` and compiles the modified *real research module* with `-c -preview=dip1000`. It requires an actual safety diagnostic. Both compilers reject:
   - `executeCopied` as `@safe` because it invokes `@system` `WorkerBatch.this/start`, `Record.reference`, `WorkerBatch.enqueue/closeAndJoin`;
   - `fromHeader` as `@safe` because `shared(TaskHeader)*` → `Record*` discards a qualified pointer boundary.
5. **Research-only fault injection:** conditional `version (M1P05Fault)` makes the *same* trusted function throw an ordinary `Exception` before enqueue slot 0, 1 or 3. Same-module unit tests assert that `finally closeAndJoin()` drains every previously accepted TaskRef and then rethrows the intended exception. The fault hook is **compiled out of the normal consumer path**, preserving the ordinary loop. This gate does **not** model native `Thread.start` failure or catastrophic `Thread.join` errors.
6. **Normal vs optimized correctness:** the real external `@safe` positive consumer now exercises singleton, full eight-entry batch, 32 successive 4-element calls, empty, oversized and null-op rejection. LDC also runs the normal consumer with `-O3` and assertions enabled. No performance verdict is derived from these correctness runs.

## Narrow trust-boundary audit

| Code region | Necessary guarantee | D compiler verdict / audit |
|---|---|---|
| `evaluateScalars` validation + snapshot | A borrowed slice is not retained; count validated | Compiler-checked `@safe`. Input is copied before spawning any worker. |
| `Record.prepare` | Prepared header, callable and int argument | **Moved to compiler-checked `@safe`** in P05. |
| `executeCopied` (parallel count 2–8) | Pinned local record addresses until all workers return; distinct records per task; exact once publication and reclamation | **Remains `@trusted` and not fully qualified.** Conversion to `@safe` rejected as expected. Trust proof spans lifetime and druntime management, not just a small unsafe primitive. |
| `Record.reference` | Cast record-header address to shared TaskRef | Private `@system`. Only used by guarded trusted bridge after preparing records. |
| `fromHeader` | Header-first layout, no alias invalidation, published records remain pinned | Short `@trusted` cast; `@safe` challenge correctly fails. Layout assertion present. |
| `execute` (typed thunk) | Invokes pointer with no capture context; writes only its own record | `@safe nothrow` checked by both compilers; correctness still depends on trusted address provenance and record lifetime. |
| `WorkerBatch` queue/condition/thread code | Publication and dequeue are synchronized; all worker accesses finish before returning stack records | `@system` internally; **manual proof still open**. Blocking and shutdown have to survive partial failure. |
| `ScalarBatchResult` readback | No read-before-join; no retained task pointers in returned struct | Ordinary test checks correct scalar values; ordering relies on `Thread.join()` in the trusted path. |

### Remaining release-blocking questions

1. **Thread startup exception window:** `started` increments only after `worker.start()` returns; whether an exceptional return can leave a live launched worker is an outstanding druntime and operating-system qualification question. P05's deterministic enqueue fault tests do not cover it.
2. **Worker fatal `Error`:** `nothrow` does not license assuming that every worker terminates normally. For instance a programmer assertion or fatal runtime error may escape the worker's `@safe nothrow` thunk. We have **not** established a shutdown/propagation protocol for this case. If a join fails before the remaining workers return, live TaskRefs must not outlive caller stack records.
3. **Join failure/partial cleanup:** a thrown `Thread.join()` would interrupt the current simple join loop; the other workers' liveness and a valid error policy have not been established. There is no blanket exception-safe memory-lifetime proof.
4. **GC and stack-frame lifetime:** scalar records contain no arbitrary GC referent, but worker delegates retain the coordinator and direct `TaskRef` pointers point into a caller frame. A broader GC/lifetime and platform model audit is needed before generalization.
5. **Callback trust laundering:** a callback declared `@safe pure nothrow @nogc` can still contain user-authored `@trusted` code with a separate, unproved promise; the library cannot prove arbitrary foreign trusted code correct. This is an ordinary D trusted-code limit, not a discovered capability to accept arbitrary closures.
6. **Soundly smaller production trust core:** the safety annotation on the worker lifecycle cannot simply be deleted. Merely moving the large `@trusted` method into a one-line trusted wrapper of an `@system` implementation does **not** reduce the **transitive** proof obligation. A later qualified worker/core mechanism must isolate thread creation, publication, return and join with independently audited safety invariants.
7. **No concurrency-performance evidence:** this slice is correctness/audit research; do not infer that singleton bypass is always faster, and do not compare scoped and owned tasks with different ownership obligations.

## Qualification evidence

**Exact code+test source commit:** `4805844b91d3b9280ebe6ca5d14d7f50b2ced912`.

[GitHub Actions run #38382063661](https://github.com/alex-1974/concurrency-d/actions/runs/38382063661):

- **DMD 2.111.0:** PASS, job **115244677964**;
- **LDC 1.41.0:** PASS, job **115244678039**;
- inherited 4-positive / 5-negative DIP1000 cases plus P01/P02/P03 runtime: PASS in both jobs;
- P04/P05 external `@safe` consumer normal and optimized LDC: PASS;
- 3 prior P04 compile-negative external consumers: PASS;
- P05 unit tests for invalid internal count/null and injected enqueue failures after 0, 1 and 3 accepted submissions: PASS;
- P05 compiler substitution challenges for launch and cast: both rejected by the intended D safety diagnostics.

An intermediate [CI run #38381970994](https://github.com/alex-1974/concurrency-d/actions/runs/38381970994) failed LDC invocation because LDC requires `-d-version=M1P05Fault` rather than DMD's `-version=M1P05Fault`. The runner now selects the compiler-specific flag; this was a **test script/toolchain-interface mistake**, not a compiler defect. The DMD job in that intermediate run passed.

Reproduce from repository root:

```bash
bash tools/research/m1_value_only_prototype.sh dmd
bash tools/research/m1_value_only_prototype.sh ldc2
```

## Disposition

**KEEP (research):** a compiler-checked safe scalar fast path; local self-validation at a trusted entry; explicit compiler proof that remaining trust markers are required; deterministic exception/partial-publication join tests.

**NO-GO (release):** production-general `@safe` concurrency claim for the complete parallel dispatch lifetime until the `@trusted` worker lifecycle, startup/join failures and worker-`Error` policy have an independent accepted proof. No promotion of P04/P05 to a frozen public API, no release benchmark verdict, no modification to `develop`.

**Next focused gate:** qualify worker lifecycle shutdown and fatal/nonfatal error policy independently of task representation, then consider a smaller audited generic worker primitive. TaskScope borrowing, nested scopes and multi-producer publication remain separate from this scalar family. Keep ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38 OPEN.
