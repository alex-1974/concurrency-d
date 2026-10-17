# M1 P02 — Lexical borrowed batch, automatic join before return

**Status:** bounded research prototype PASS on DMD 2.111.0 and LDC 1.41.0, including LDC `-O3` correctness, **not an accepted TaskScope API**.

Links: [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [proposed ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [P01 evidence](../p01_scoped_join/README.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Hypothesis and contract tested

P01 proved that an *explicitly invoked* `closeAndJoin()` can drain pinned, caller-owned `TaskRef` records. P02 asks whether we can remove **forgotten joins** from the most limited scoped task family without weakening the accepted transport:

```d
// Research-only, intentionally private and @system:
private BatchResult runScopedBatch(scope Work[] callbacks) @system;
```

The operation is synchronous and non-detaching: all accepted callbacks finish and the worker threads return **before** this function returns. Every record is a member of a pinned, local `Record[8]`. A P02 caller cannot obtain a TaskRef or task-record address from this interface, cannot open a task handle, and cannot forget a separate join. This is an intentionally limited lexical **batch**, not a general dynamic `TaskScope` with work spawned at arbitrary nesting levels.

`scope Work[]` is the D frontend annotation on the incoming **slice**. It is NOT a transitive lifetime/capture safety theorem for each callback; `runScopedBatch` is correctly **`@system`** and must remain so until a qualified contract enforces borrowed referent validity and race freedom. The callbacks themselves have `@safe` bodies; that doesn't certify cross-thread interactions with captured objects.

## Mechanism

- Reuses the real M0 `TaskHeader`, `TaskRef` and `dispatchTask` from `source/concurrency/internal/task_record.d`. Universal transport remains an eight-byte non-owning `TaskRef`.
- Defines private `Record`, with header-first layout, callable, `Exception` slot and a release/acquire `returned` marker. `@disable this(this)` prohibits ordinary copy construction; a compile-time assertion verifies the specific copy form. It cannot outlaw arbitrary raw memory movement from `@system`.
- P02 constructs a local `Record[8]` and prepares **all records before worker creation**. It checks `callbacks.length <= 8` with an explicit `Exception` even with asserts disabled. An oversized batch is rejected before any job is published.
- A private, GC-allocated two-thread coordinator stores a bounded eight-entry FIFO of non-owning TaskRefs. This scheduler choice isolates lifetime semantics, **not** production scheduling performance.
- Publication, dequeue and closing use a common mutex/condition. The coordinator is closed in a `finally` block, workers drain all accepted jobs, and their `Thread.join()` calls complete before the local records become invalid. Publication/worker startup exceptions must also take the join path.
- Callback `Exception` values are caught in the internal `@safe nothrow` execute thunk, then counted **after** join; callback errors do not abandon sibling jobs. Worker returns are marked only after dispatch. `Error`/fatal-process behavior is not qualified.
- `BatchResult` is an internal summary `{accepted, returned, exceptions}` rather than a detached future. It can be returned safely as values because all submitted TaskRefs are quiescent.
- The only `@trusted` runtime cast is a short conversion from the shared header pointer to the private pinned record. Another `@trusted` *test helper* invokes the druntime GC collection API; it must not be mistaken for a task submission safety claim. The P01-style broad `@trusted` wrapper for nested async execution was **removed**, rather than treating an unproved nested join as safe.

## Reproduce (repository root)

```bash
bash tools/research/m1_lexical_batch_prototype.sh dmd
bash tools/research/m1_lexical_batch_prototype.sh ldc2
```

Both jobs compile P02 **alongside the existing real M0 task transport**, with `-preview=dip1000`; the LDC runner also compiles and runs **`-O3` with assertions ENABLED**. This is an optimized **correctness** check, not a benchmark or production `-release` qualification.

## Executed controls

| Control | What it actually checks |
|---|---|
| Four distinct caller-local `shared uint` borrows | Each scoped callback writes its own target with an atomic operation; all records returned when the call finishes. |
| Ordinary child `Exception` | One failing callback records its error, two sibling callbacks still execute, then `BatchResult.exceptions == 1`. |
| GC-visible capture | A callback captures a GC-allocated class, explicitly triggers `GC.collect()` in a test-only trusted helper, and accesses the retained object correctly. A single run **does not establish arbitrary GC-root correctness**. |
| Destruction ordering | A noncopyable local guard checks that work has completed before destruction and that its destructor runs once on lexical block exit. |
| Empty batch | Completes without threads/work. |
| Nine callbacks (capacity eight) | Throws an explicit `Exception` **before** publishing any callback; execution count stays zero. |
| Repeated lifetime cycles | 32 synchronous batches of eight callbacks each execute and join successfully, with the expected cumulative atomic count; no previous TaskRef storage survives the call. |
| Noncopyable Record | `static assert(!__traits(compiles, { Record a; Record b = a; }))` holds on both supported frontends; other forms of untrusted relocation are NOT qualified. |

These controls add to the previous P01 full/duplicate/closed queue proof and the existing four-positive/five-negative language-probe suite. P02 does **not** republish or consume the full P01 general dynamic-submission model.

## Evidence

**Exact source commit with all rows above and pinned optimized LDC runner:** `d0b6dfceb66398f93ecb4a60543216105ff681f0`.

[GitHub Actions run #38376599810](https://github.com/alex-1974/concurrency-d/actions/runs/38376599810) — all jobs **PASS**.

- DMD 2.111.0 — job **115226436286**, P01 + 9 DIP1000 language controls + P02 PASS.
- LDC 1.41.0 — job **115226436552**, P01 + 9 DIP1000 language controls + P02 twice (normal and `-O3`) PASS.
- Both job logs explicitly show `P02 lexical batch: PASS (automatic join, stack/GC borrows, exception drain, capacity rejection, 32 cycles, destructor order)`. LDC prints this twice for normal/`-O3`.

The prototype was initially introduced in `78db5585f226f7bd3c07d929fb9ef310712c16ac`; that first run passed but still included a too-broad test-only `@trusted` nested worker wrapper and a debug-only batch capacity assertion. Both were corrected **before** the current evidence was frozen. Removed nested coverage is an intentionally restored OPEN gate, not a regression hidden by relabeling the test.

## Remaining safety/functional gates

1. A future dynamic `TaskScope` still needs a lexical API that ensures child callbacks cannot capture objects with a lifetime shorter than the join. P02's synchronous **single call** avoids forgotten joins, but arbitrary D delegate capture graphs and thread safety are **not certified by `scope`**.
2. The API is `@system`. Existing compile-negative DIP1000 tests verify elementary source escapes, **not** safe consumer calls to a real scoped work-submission API. Do not claim a `@safe` TaskScope without new positive and negative consumer fixtures tied to the actual interface.
3. P02 records are allocated on the caller's stack, and the coordinator allocates GC objects and two native threads **per batch**. This is a semantics investigation, not a performance winner against M0 owned jobs or any C++ runtime.
4. Separate producer-vs-close races are structurally absent from the synchronous P02 interface; they remain relevant for a future dynamic Scope and for P01. There is no nested worker-pool join proof, general cancellation propagation, typed result, full GC root/destructor-count matrix, `Error` unwind guarantee, or broad cancellation/exception protocol.
5. The test's GC capture is not a guarantee that all sorts of captured GC-managed graphs are rooted correctly during concurrent collections. This needs deliberate GC stress plus lifetime analysis when storage is specialized.
6. A later real consumer should justify dynamic spawn/structured child behavior before we introduce a more elaborate scope state machine. Performance qualification must compare semantically equivalent task families and optimized real workloads.

**Disposition:** P02 establishes a viable **limited synchronous borrowed-batch** lifetime mechanism (research KEEP); full general `TaskScope` and static cross-thread borrow safety remain **DEFER**. Keep ADR PROPOSED, Issue #17 OPEN and Draft PR #38 DRAFT. `develop` and R0.5 PR #35 were not modified.
