# M1 P01 — Pinned scoped TaskRef queue with explicit join

**Status:** Research-only P01 **PASS on the bounded tested scenarios**; *no public TaskScope, no general `@safe` claim, no performance baseline*. Design issue [#17](https://github.com/alex-1974/concurrency-d/issues/17) and [proposed ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md).

## What is actually implemented

- Reuses the repository's unchanged package-internal `TaskHeader`, `TaskRef` and `dispatchTask` from `source/concurrency/internal/task_record.d`. The hot task transport is still **one 8-byte non-owning pointer**.
- Caller-frame fixed `ScopedRecord[N]` arrays; record addresses do not move after publication. A record has header, delegate, exception slot, and *post-dispatch* release/acquire `returned` marker. The scheduler owns **no task record or delegate**; the lexical caller keeps both alive until join.
- A minimal two-worker research scheduler with an eight-entry mutex-protected FIFO inbox; **the scheduler type itself is GC-allocated**, but its task records are not.
- A single controller calls `start()`, `trySubmit(ref ScopedRecord)`, optional `requestCancel()`, then `closeAndJoin()`. `trySubmit` and close share the same mutex; close rejects further admissions. Each successfully submitted record may be published **at most once**. Full/duplicate/closed submissions reject without creating an obligation.
- A worker claims a TaskRef, dispatches through the qualified thunk, stores `returned` **after** dispatch, then records completion. `closeAndJoin` wakes sleepers, drains accepted tasks, joins every started native thread, then asserts `accepted == returned`.
- Callback `Exception` instances are stored per-record and inspected **only after** join. Cancellation is only a cooperative *request*: no accepted task is cancelled, detached, unrooted or destroyed early.
- The unsafe boundary of the internal `executeRecord` callback is limited to a single `@trusted` cast from the header-first shared `TaskHeader*` back to the owning, pinned `ScopedRecord*`. The callback itself has a declared `@safe` delegate signature and executes **outside** the cast helper. The external record setup/submission API is **`@system`** because callback capture lifetime and cross-thread safety are not statically proved.
- `Gate` exists only to make blocked-worker/queued-work tests deterministic; its `@trusted` methods wrap `Condition.wait/notifyAll`, marked `@system` in these pinned druntime versions, with the relevant test mutex acquired.

## Reproduce

From repository root, with DMD 2.111.0 or LDC 1.41.0 available:

```bash
bash tools/research/m1_scoped_join_prototype.sh dmd
bash tools/research/m1_scoped_join_prototype.sh ldc2
```

The runner compiles **the real M0 task-record module** and this P01 source with `-preview=dip1000` into an isolated executable, then executes it. It requires neither DUB nor the `containers-d` runtime: the purpose is **task-record and join semantics**, *not* R0.3/R0.4 work-stealing scheduler performance.

### Executed scenarios

1. **Pinned queue + backpressure + close**: two workers blocked behind a test gate, eight queued tasks, 11th record rejected as full; duplicate record rejected while capacity remains; gate releases, all ten accepted records execute and mark returned; rejected record remains never-published; submission after join rejects.
2. **Borrowed caller stack**: three queued tasks use three **distinct** pointers to a caller-local fixed `int[3]`; caller uses `finally closeAndJoin()`; all three values are updated correctly and every published record reports post-dispatch return before the stack frame ends.
3. **Exceptions and cooperative cancellation**: one callback throws an `Exception`, two continue normally, a cancellation request is observed but does not release storage, a caller-side exception triggers `finally closeAndJoin()`, and after join the recorded child failure and all returned markers are inspected.

### Reproducible diagnostic discovered

The first runtime version constructed closures by capturing an ordinary loop-local pointer. **Both** pinned compilers produced a wrong-target assertion in the three-stack-slot test (not a compiler defect claim). The revised source uses an explicit factory `borrowedAdd(pointer)` to create a distinct closure frame for each task. The test passed on both compilers after this change. This illustrates why the future API may not assume independently owned captures from arbitrary loop-created delegates without qualification.

## Pinned evidence

Exact executable source commit **`3e6a11716010f39bef31d40516e42e0aee955ca8`**:

- [GitHub Actions run #38375308191](https://github.com/alex-1974/concurrency-d/actions/runs/38375308191) — **PASS**, both jobs.
- DMD 2.111.0, job **115222076585** — `P01 scoped join: PASS (pinned refs, queue full/duplicate/close, join, stack borrow, exceptions, cancellation request)`.
- LDC 1.41.0, job **115222076222** — the same runtime PASS.
- Existing language gate also passed: **4 positive / 5 negative compile-only DIP1000 fixtures** under both compilers.

Intermediate CI results are retained, not rebranded as success:
- [#38374713993](https://github.com/alex-1974/concurrency-d/actions/runs/38374713993): first source used reserved D `ref`/`scope` identifiers (build failure).
- [#38374846300](https://github.com/alex-1974/concurrency-d/actions/runs/38374846300): compiler correctly rejected catching `Throwable` in `@safe` and flagged `Condition` methods as `@system`; source was narrowed to `Exception`.
- [#38374942200](https://github.com/alex-1974/concurrency-d/actions/runs/38374942200): runtime stack-capture wrong-target assertion in both compilers.
- [#38375085322](https://github.com/alex-1974/concurrency-d/actions/runs/38375085322): first passing P01 runtime.
- [#38375308191](https://github.com/alex-1974/concurrency-d/actions/runs/38375308191): passing P01 plus full-queue/duplicate/closed rejection coverage.

## Explicit remaining blockers

- **No leak-proof public API:** `ScopeKernel` methods and record preparation are `@system`; the user must keep every borrowed referent alive and call join before stack exit. No compiler proof prevents the caller forgetting `closeAndJoin()`. The `try/finally` tests validate a usage pattern, not static enforcement. No automatic destructor-based safe unwind.
- **No user-supplied dynamic `TaskScope` borrow checker**: only the separate nine basic compile probes cover specific local `scope`/DIP1000 escapes; no negative test against P01's `@system` operations would meaningfully qualify `@safe`.
- **Single external join owner** only. Concurrent close/join calls and worker self-join are not provided; no static bound on capture lifetime across outside producer threads. `ScopedRecord` is not copy-disabled, so clients must honor the fixed-address contract manually.
- **No general failure protocol:** only ordinary `Exception` is caught by the `@safe nothrow` thunk. Fatal D `Error`, nested scopes, structured propagation of multiple child failures, typed results, cancellation propagation, unstarted task abandonment and partial start errors are not fully qualified.
- **No work stealing or consumer equivalence:** P01 uses a mutex FIFO to isolate the lifetime proof. It is **not** the current owned executor, does not imply a scheduler optimization, and is not a benchmark versus C++/GC-owned jobs.
- **No GC-stress or destructor-count proof yet** for captured heap references or move-only resource types; test this next. Concurrent producer/close adversarial interleavings also remain open.

## Next small slice (P02)

Model a lexical API that cannot let caller borrows leave before a joined quiescence point (as far as supported by D's `scope` annotations), with pinned/non-copyable records and intentionally **no detach**. Add tested cancellation/exception unwind and GC-visible capture/reclamation, plus concurrent producer versus close only with explicit producer lifetime ownership. Do **not** promote `@safe` or public TaskScope until the compiler-negative and runtime qualifications can justify them.

PR #38 stays **Draft**, ADR-0001 **PROPOSED**, Issue #17 **open**, `develop` and grandfathered PR #35 untouched.
