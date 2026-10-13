# M1 P04 — A constrained `@safe` scalar execution envelope

**Status:** research qualification PASS for the narrow typed facade under DMD 2.111.0 and LDC 1.41.0, including optimized LDC `-O3` correctness. **NOT a public generic `@safe TaskScope` acceptance.**

Related: [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [P03 dynamic `@system` portal](../p03_dynamic_lexical_scope/README.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Why P04 exists

P03 showed that an outer join does **not** protect a borrow made to an inner block in a dynamic producer: that block can die while a submitted child is still executing. Marking arbitrary dynamic `TaskScope` submission `@safe` would be unjustified. P04 instead asks whether we can use D's **actual type system** to offer one intentionally narrow, `@safe`-callable execution family without those capture hazards.

## Proposed limited boundary

```d
alias ScalarOperation = int function(int) @safe pure nothrow @nogc;

struct ScalarBatchResult
{
    size_t count;
    int[8] values;
}

ScalarBatchResult evaluateScalars(
    scope const(int)[] inputs,
    ScalarOperation operation) @safe;
```

This prototype's module is compiled from **research sources only**, not from the public DUB source path. It is *not* a frozen consumer API.

- Input is a borrowed `const(int)[]` only **until synchronous snapshot**; no worker receives its pointer. All at most eight values are copied into a plain `int[8]` array **before** creating any thread.
- The callback is an ordinary **function pointer**, not a `delegate`: no arbitrary closure context/capture can be stored in a task record through this signature.
- `@safe` restricts the callback's memory operations; `pure`, `nothrow` and `@nogc` further constrain this intentionally very small computation class. The function returns a scalar value. `pure` is useful for excluding observable mutable global state; it is not a promise of deterministic timing or freedom from all conceivable effects in external `@trusted` code.
- The operation is synchronous; workers are always joined before copied scalar results leave the method. There is no handle, detach path, cancellation, borrowed return pointer or mutable shared user reference.

## Manual trusted boundary — review obligations

The public research entrypoint is compiler-checked **`@safe`**. The sole substantial bridge into druntime thread and condition-variable APIs is a **private `@trusted executeCopied(int[8], size_t, ScalarOperation)`**. A second tiny `@trusted` header-first cast translates a qualified `TaskRef` into an internal `Record*`.

The trust argument is deliberately finite:

1. The `@safe` entrypoint validates count **at most eight** and nonnull operation, then snapshots all user integers while still in the caller thread. Only integers and a function pointer cross into the trusted bridge.
2. The private `Record[8]` is constructed and prepared before worker startup. Every record contains only header, function pointer, one input and one output `int`. `@disable this(this)` rejects ordinary copying of a published record.
3. Each `TaskRef` points to a distinct prepared record with header at offset zero. The bounded queue never contains any raw user-supplied pointer and no record is republished.
4. Each task's callback is a `@safe pure nothrow @nogc` **function pointer without a D delegate context**, called with a copied `int`. Concurrent workers write only their **own** record's result.
5. All queue publication/claim operations use the internal mutex. The driver closes and calls `Thread.join()` in a `finally`, even after exceptions during publication; partial thread creation has a cleanup path. Results are read only **after all workers returned**.
6. The returned result is a fully by-value `ScalarBatchResult`. No pointers to stack records or borrowed user input can escape this boundary.

**IMPORTANT:** marking `executeCopied` `@trusted` is a **research hypothesis with a manual proof obligation**, not something that compiler acceptance validates automatically. It spans an internal worker lifecycle and requires line-by-line safety review. For production, further reduce and independently audit this boundary or use a smaller validated worker primitive. Fatal `Error`, allocator/thread-start catastrophic failure, hostile `@trusted` code in a user function pointer, all possible platform memory-model and druntime failure paths remain unqualified. It would be incorrect to generalize this result to closures capturing arbitrary user memory.

## Executed real-consumer matrix

A separate positive consumer imports `concurrency.research.m1_value_scope` and invokes `evaluateScalars` **from a function explicitly annotated `@safe`**. It checks:

- four copied values produce correct results;
- 32 successive bounded calls do not retain a task pointer to a prior invocation;
- empty batch works;
- oversized batch rejects before spawning;
- null operation rejects before spawning.

Three separate **compile-negative external consumers** use the same real P04 module and compile-only flags:

| Consumer file | Must fail because |
|---|---|
| `negative_captured_delegate.d` | A delegate with a capture/context is not a `ScalarOperation` function pointer. |
| `negative_system_function.d` | A `@system` function cannot meet the `@safe` operation signature. |
| `negative_nonpure_function.d` | A function lacking `pure` cannot meet the operation signature. |

Both DMD and LDC logs have been checked for the **intended `evaluateScalars is not callable using argument types`** diagnostics, not just a nonzero exit code.

**Compiler evidence source commit:** `d1a584980ae790881b9080b75900a1efb218899d`.
[GitHub Actions run #38378940463](https://github.com/alex-1974/concurrency-d/actions/runs/38378940463), DMD job **115234237356** and LDC job **115234237300**: **PASS**. LDC's `-O3` with assertions enabled also PASS. All original nine language fixtures and P01/P02/P03 runtime checks remained passing on that source commit.

Reproduce from repository root:

```bash
bash tools/research/m1_value_only_prototype.sh dmd
bash tools/research/m1_value_only_prototype.sh ldc2
```

The negative probes are compile-only. The positive consumer is a linked executable; no linker failure counts as negative success.

## Decision: what this does and does not prove

**KEEP as constrained research:** The normal D compiler can enforce an **actually narrower user callback type** than P03's arbitrary borrowed delegate. A real `@safe` external caller executes useful work through that boundary, and code with captured delegates, unsafe function pointers or nonpure functions is rejected.

**NO-GO for claiming this solves Issue #17's general dynamic TaskScope:** There are no borrowed closure captures, no arbitrary returned result type, no dynamic child submissions, no parallel external producers, no nested worker-side scope, no cancellation and no performance qualification. The narrow `@trusted` runtime proof needs independent review; source-level negative tests do not prove the internals safe. The design also snapshots eight input scalars rather than exercising a general borrowed view. This is a **different task family**, not evidence that arbitrary borrowed tasks become `@safe` after an outer join.

**Next research gate:** compare the feasibility of typed, copyable, alias-free values against a *separate* explicit `@system` borrowing family; qualify the `@trusted` bridge and worker shutdown corner cases before any promotion; only then consider generic typed results, cancellation or realistic consumer measurements. Continue to preserve P01–P03 and the R0.5 research evidence.


## P05 follow-up — limited trust reduction and independent blockers

The original P04 result above describes the **pre-P05** implementation and its pinned CI source. Later work **on this same research module** is tracked separately as [P05 trusted-boundary audit](../p05_trust_audit/README.md).

P05 now executes count 0 and 1 *entirely through compiler-checked `@safe` code*; only count 2–8 can cross the `@trusted` worker-lifecycle function. The internal trusted method validates its own count/non-null operation before allocating or publishing any records; `Record.prepare` is compiler-checked `@safe`. A test-only version hook injects ordinary exceptions after 0, 1 and 3 enqueue attempts and demonstrates quiescent join-before-rethrow. Both trust markers were individually challenged as `@safe` and rejected for the anticipated compiler safety reasons.

[Updated CI evidence #38382063661](https://github.com/alex-1974/concurrency-d/actions/runs/38382063661): DMD 2.111.0, LDC 1.41.0 and optimized LDC normal consumer PASS. **The parallel `@trusted` worker lifecycle still has unsolved thread-start, fatal-Error, join-failure and transitive-soundness proof obligations. P05 explicitly does NOT accept or promote a production-safe parallel TaskScope.**
