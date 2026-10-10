# M0 owned callable + TaskHandle prototype (issue #11)

Status: experimental package-internal implementation, **not public API**.

## Goal

Move from externally retained scalar function pointers to a real
`submit` → `TaskHandle!R.get()` execution path. Keep R0.2's one-word
`TaskRef` and first-field `TaskHeader`. Store concrete callable,
result and error handling in a type-specialized node.

## Lifetime and safety

- `OwnedTaskExecutor` explicitly owns its `SubmissionWorkerPool`.
- The concrete GC-managed `OwnedNode!(F,R)` contains a header-first record;
  its storage is retained by an executor-owned strong-reference list.
- A `TaskHandle!R` holds a separate GC-managed result cell with its own
  mutex/condition; `get` may block and rethrows the captured failure.
- Dropping the result handle does not cancel the accepted task.
- `submit` accepts arbitrary D callable values under **`@system`**.
  This is intentional: copying a delegate/closure does not prove the
  lifetime of borrowed captured data or cross-thread mutation safety.
- The node catches `Throwable` at the type-erased execution boundary
  so the worker accounts completion even if user code throws. Ordinary
  exception propagation is exercised by tests; unrecoverable process errors
  are not made safe by capturing them.
- Admission `full` unwinds the provisional root. `closed` rejects.
  The retained-record cap is explicit; records are **not recycled before
  shutdown** in this initial correctness prototype.

## Representation decision being tested

Existing qualified research used an `@safe @nogc nothrow` execute pointer.
Arbitrary user callables can allocate or throw; a thunk wrapping user code
cannot promise `@nogc`. The experimental header remains one word but
its execute pointer is now `@safe nothrow`, while the specialized thunk
owns exception capture. This removes an attribute from the *dispatch*
boundary, not from the internal deque/atomic scheduling primitives.

The cost of this trade-off must be measured after correctness on DMD/LDC.
There is no universal performance claim and the API remains revisable.

## What remains

- Incremental record reclamation/reuse instead of retention until join.
- Audit for noncopyable/move-only F and R and address-stable object storage.
- Compile-negative `@safe` borrow escape tests and supported capture rules.
- Public API shape, error typing, execution from inside other task contexts.
- Deterministic shutdown and same-task wait deadlock policy.
- Real consumer smoke with documented package exports and attributes.

## Validation

`dub test --compiler=dmd --force`,
`dub test --compiler=ldc2 --force`, release builds, and native ARM64
through the repository's existing CI. The first PR is draft until these pass.
