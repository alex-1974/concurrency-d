# M1 — DMD/LDC DIP1000 lifetime probe results (2026-10-13)

**Scope:** positive/negative *compiler-only* language-property controls for [#17](https://github.com/alex-1974/concurrency-d/issues/17). **Result: PASS for this narrow language gate**, on exactly the fixture source commit **`09c3c349c8fefa4ec7b3b77e6798af52112b75b5`** (source files, runner and workflow). This record does **not** qualify a `TaskScope`, arbitrary `@safe` concurrency, or any performance mechanism.

**GitHub Actions:** [M1 task lifetime compile probes — Run #38372933369](https://github.com/alex-1974/concurrency-d/actions/runs/38372933369), pull-request event on Draft [PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

Both jobs completed successfully:
- `DIP1000 / dmd-2.111.0`: **PASS** — 3 positive compilation successes and 4 intended negative source rejections.
- `DIP1000 / ldc-1.41.0`: **PASS** — same 3 positive successes and 4 intended negative rejections.

Each source was compiled with **`-c -preview=dip1000`**, with isolated output object paths. The negative fixture's compiler failure was **not** a linker failure or an arbitrary setup error. Both compilers printed the same specific semantic rejection classes:

| Negative fixture | Verified diagnostic reason on both compilers |
|---|---|
| `negative_scope_return.d` | plain `scope` parameter `values` may not be returned |
| `negative_scope_global.d` | assignment of `scope` `values` to longer-lived global `escaped` forbidden in `@safe` |
| `negative_ref_escape.d` | returning `&value` would escape a reference to non-`return` parameter |
| `negative_stack_escape.d` | returning `storage[]` would escape the local `storage` |

Each corresponding positive control compiled:
- `positive_scope_local.d` — consumed local slice without escape.
- `positive_return_scope.d` — explicit caller-bound `return scope` propagation.
- `positive_return_ref.d` — explicit `return ref` address propagation.

**Integrity:** job IDs **115214125424** (DMD) and **115214125147** (LDC). The job logs were checked for all seven PASS lines **and** the actual error text, not merely overall workflow success. Pin the original workflow run to `09c3c349...`; a later documentation-only commit does not rewrite that tested fixture identity.

## Interpretation

This confirms only these **specific** compiler rules under the stated toolchain/flags. It does **not** imply a general borrow checker, nor that `scope` makes a closure safe for parallel execution. These probes are self-contained and do not exercise the experimental `OwnedTaskExecutor` or a nonexistent `TaskScope`.

**Next gate:** design a small explicitly joined scope prototype with address-stable records and no detach; verify capture lifetime, structured unwind and worker completion before any `@safe` claim. Preserve M0's `@system` general callable submission and its strong GC-root semantics. No scheduler code was changed or benchmarked by this research.

**Change discipline:** keep the ADR at **PROPOSED**, PR #38 **Draft**, Issue #17 **open**; Draft PR #35 and `develop` remain unchanged. This results file is evidence, not production acceptance.

## Extension: captured `scope delegate` — both compilers PASS

The focused callback/capture pair was added **after** the initial seven-fixture run. Source HEAD containing the two fixtures and updated runner/README: **`70d4c4fab1662fd239be2777c0a281d6e874d126`**.

**Exact-source CI:** [M1 task lifetime compile probes — Run #38373354672](https://github.com/alex-1974/concurrency-d/actions/runs/38373354672).

- DMD 2.111.0, job **115215505062**: **PASS — 4 positive + 5 negative**.
- LDC 1.41.0, job **115215505618**: **PASS — 4 positive + 5 negative**.

Both logs explicitly record:
- `PASS positive: positive_scope_delegate` — a captured `@safe` delegate passed to a `scope` argument for synchronous local invocation compiled.
- `PASS negative rejected: negative_scope_delegate_escape` — diagnostic: assigning `scope` variable `action` to global `escaped` is forbidden inside `@safe`.

The other seven fixtures also continued to PASS at this source commit. This is **not** evidence that storing, enqueueing or invoking an arbitrary closure across worker threads is safe; only lexical/scope parameter escape behavior is tested.

**Current language gate:** **4 positive / 5 negative, DMD and LDC PASS**. The outcome is narrower than Issue #17's full scope/ownership acceptance conditions; leave ADR status PROPOSED and PR #38 Draft.
