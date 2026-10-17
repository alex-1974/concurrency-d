# M1 lifetime research — initial DMD/LDC gate

**Issue:** [#17](https://github.com/alex-1974/concurrency-d/issues/17). **Status:** research-only compile probes; not a TaskScope implementation or accepted `@safe` API.

## Purpose

Establish exactly which **limited** D language escape conditions are enforced by DMD 2.111.0 and LDC 1.41.0 under `-preview=dip1000`, as one prerequisite for a future TaskScope design. The positive control and negative source are standalone D modules; they use no scheduler import, so they **cannot** be confused with proof of correctness of any cross-thread execution mechanism.

The selected fixtures deliberately distinguish three relationships:

| Positive control (must compile) | Negative (must be rejected) | Target property |
|---|---|---|
| `positive_scope_local` | `negative_scope_global` | Local use of scope data is allowed; retention in module global is disallowed |
| `positive_return_scope` | `negative_scope_return` | An explicitly `return scope` borrow can return; plain `scope` cannot |
| `positive_return_ref` | `negative_ref_escape` | Explicit `return ref` may derive returned pointer; ordinary `ref` cannot |
| `positive_scope_local` | `negative_stack_escape` | Borrowed local slice use is valid; returning a local stack slice is not |
| `positive_scope_delegate` | `negative_scope_delegate_escape` | Locally captured `@safe` delegate may be synchronously invoked via a `scope` parameter; cannot be stored in longer-lived global state |

## How to run

From the repository root:

```bash
bash tools/research/m1_lifetime_compile_probes.sh dmd
bash tools/research/m1_lifetime_compile_probes.sh ldc2
```

The script uses **`-c -preview=dip1000` for all nine compilation attempts**, isolated output object paths and a unique temporary directory. It checks that every positive fixture compiles and each negative fixture produces a compiler **failure**. Diagnostics are printed but not pattern-matched to a fragile wording. The test is compile-only, not a linker-error acceptance test.

The pinned CI definitions, when actually run, use `dmd-2.111.0` and `ldc-1.41.0` on Ubuntu 24.04. A CI workflow run with final PASS is required before reporting qualified compiler evidence; a successful workflow definition commit is **not** itself evidence that compilers accepted or rejected the source.

## Limits of inference

- This checks **D frontend escape analysis**, not whether a scope's child tasks actually finish before parent references die.
- The probes do **not** cover closure capturing, storage relocation, `TaskHandle` ownership, concurrent mutation, `@safe` scheduler submission, GC reachability, release/acquire, exception unwinding, real destruction timing, join deadlock, or cancellation.
- A negative compile rejection is only meaningful alongside the closely related positive control; an unexecuted fixture is not a verified PASS.
- The compiler cannot be treated as a universal borrow checker. D language scope constrains selected indirections under checked `@safe` code; `@system` can bypass these checks.
- Neither `@nogc` on small sample functions nor compiling an unrelated positive demonstrates a `@nogc` scheduler.

Both the original seven-fixture gate and the subsequent captured-delegate extension have **verified DMD 2.111.0 and LDC 1.41.0 PASS** (4 positive and 5 negative in the final source matrix). See [pinned CI results and exact source identities](results/ci-lifetime-compile-review-2026-10-13.md). These are language-property proofs only, not TaskScope runtime or `@safe` concurrency evidence.

## Next qualification (not implemented here)

Introduce a minimal internal scope ownership carrier and explicit join barrier with *pinned* TaskRef records. Add positive/negative compile probes **against that API** where the compiler can prove forbidden escapes; for runtime-only invariants test worker handoff, post-dispatch return, shutdown races, GC-visible capture, exception-safe drain, nested scopes, cancellation and exact destruction. Do not claim a speedup or create a new public API until those gates pass.

**Branch choice:** this isolated research branch starts from the exact current M0 `develop` baseline, rather than importing 137 unrelated commits from the diverged `research-integration` history; existing grandfathered PR #35 and other research branches remain intact.
