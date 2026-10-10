# R0.2 P03 — TaskRecord header and cache locality

Status: PASS

## Decision

Keep the scheduler-visible TaskRecord header minimal.

Selected hot header entering P04:

```d
struct TaskHeader
{
    ExecuteFn execute;
}
```

Layout:

```text
TaskHeader = 8 bytes
TaskRef    = 8 bytes
```

Do not pre-allocate cancellation, result, scope, or other future R1 fields in
the universal hot header without separate evidence.

## Probe layouts

P03 compared records with identical first-field execute metadata and increasing
speculative scheduler metadata:

```text
MinimalRecord       16 bytes
StateRecord         24 bytes
ScopeRecord         32 bytes
Speculative64Record 64 bytes
```

All records used the same 8-byte TaskRef and the same indirect dispatch shape.

Two access patterns were measured:

- sequential record traversal;
- deterministic shuffled pointer traversal.

The latter models scheduler/task graphs where record addresses do not have
linear locality.

## LDC 1.41 hosted x86_64

Representative zero-round shuffled dispatch:

```text
minimal-16       3.799 ns/task
state-24         3.246 ns/task
scope-32         9.344 ns/task
speculative-64  12.747 ns/task
```

Representative eight-round shuffled dispatch:

```text
minimal-16      26.159 ns/task
state-24        28.978 ns/task
scope-32        53.442 ns/task
speculative-64  67.213 ns/task
```

Small differences between 16 and 24 bytes are not monotonic on the hosted
machine and should not be overinterpreted.

The important result is the large locality penalty once every record is
unconditionally widened to 32 or 64 bytes.

## Native AArch64 / LDC 1.41 / Neoverse-N2

Zero-round shuffled dispatch:

```text
minimal-16       7.736 ns/task
state-24         7.991 ns/task
scope-32         8.459 ns/task
speculative-64  10.797 ns/task
```

Eight-round shuffled dispatch:

```text
minimal-16      22.156 ns/task
state-24        20.854 ns/task
scope-32        22.662 ns/task
speculative-64  52.627 ns/task
```

Again, individual 16/24/32-byte ordering is architecture/workload sensitive.
The 64-byte always-wide record has a clear cache-footprint cost.

## DMD 2.111

DMD correctness passed.

Its shuffled measurements also show a large penalty for 32/64-byte records,
with especially high variance for pointer-chasing. DMD remains a correctness
and code-shape compiler rather than the primary optimized-performance baseline.

## Interpretation

P03 does not claim that a 24-byte record is always faster than a 16-byte record
or vice versa.

It establishes a more important architectural rule:

    universal metadata has a real cache cost

especially when task records are reached through non-local pointers.

Fields required only by some future task forms should not automatically become
part of every TaskRecord header.

## Selected header contract

The minimal universal scheduler metadata remains:

```text
execute target
```

The execute target is initialized before TaskRef publication and loaded from
shared metadata using safe atomic load.

Additional fields require later evidence:

- task state: when R1 state transitions are designed;
- scope linkage: when structured TaskScope is designed;
- cancellation: R1;
- typed result storage: R1;
- allocator/pool metadata: R0.5.

Concrete task records may contain payload-specific state after the header.

## Type-erasure boundary

A type-specific execution thunk may recover its concrete task record from a
pointer to the first-field TaskHeader.

That concrete downcast is a narrow generated type-erasure boundary and must be
qualified separately from ordinary scheduler dispatch.

Normal scheduler dispatch itself remains:

```text
@safe @nogc nothrow
```

## Next gate

P04 — structured lifetime model.

P04 must prove that the selected non-owning TaskRef can safely participate in
a structured stack-resident lifetime when all workers complete before the
owning scope returns.
