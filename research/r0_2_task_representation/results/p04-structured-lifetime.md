# R0.2 P04 — Structured task lifetime

Status: PASS

## Selected lifetime model

TaskRef remains non-owning:

```d
struct TaskRef
{
    shared(TaskHeader)* ptr;
}
```

A referenced task record may be stack-resident when the owning structured scope
guarantees:

```text
all queued, stolen, executing and otherwise in-flight TaskRefs are finished
before the owning stack frame returns
```

The queue does not participate in reclamation.

## Runtime qualification

P04 created 1,024 concrete task records as a local stack array.

The owner:

1. initialized execute metadata and payload;
2. published TaskRefs through the production containers-d WorkStealingDeque;
3. started another thread;
4. allowed the worker to steal and execute every TaskRef;
5. joined the worker;
6. verified exactly one execution for every record;
7. returned only after all references were consumed.

Result:

- DMD 2.111 / x86_64: PASS;
- LDC 1.41 / x86_64: PASS;
- LDC 1.41 / native AArch64: PASS.

The same TaskRef/dispatch path also passed with externally owned stable storage.

## Direct escape negative test

A dedicated DIP1000 compile-negative attempted:

```d
@safe TaskRef escapeStackTask()
{
    shared TaskHeader local;

    return TaskRef(&local);
}
```

Both baseline frontends rejected it with the relevant diagnostic:

```text
returning TaskRef(& local) escapes a reference to local variable local
```

This negative gate also passed on the native AArch64 LDC frontend.

## Static versus structured enforcement

DIP1000 can reject obvious direct returns of a reference to local storage.

It cannot by itself express the complete semantic lifetime of arbitrary
TaskRefs once they have been published into concurrent queues and worker
state.

Therefore the production model must combine:

- language lifetime checking where available;
- non-owning TaskRef semantics;
- structured scope ownership;
- join/completion before owning storage is destroyed.

## Type-erasure boundary

Ordinary scheduler dispatch remains:

```text
@safe @nogc nothrow
```

A type-specific generated thunk may recover its concrete record from the
first-field TaskHeader. That cast is the narrow type-erasure boundary.

The scheduler itself does not need to know the concrete task payload type.

## Allocation separation

P04 deliberately does not select an allocator.

The same TaskRef works with:

- stack-resident structured records;
- externally owned stable records;
- future pooled records.

Pool/slab design remains R0.5.

## Decision entering P05

Selected representation/lifetime direction:

```text
TaskRef
    8-byte non-owning shared(TaskHeader)*

TaskHeader
    8-byte execute target

metadata publication
    initialized before queue publication
    safe atomic load by executor

stack lifetime
    allowed only under join-before-return structured ownership
```

## Next gate

P05 — scheduler-neighborhood integration.

The selected representation must now be exercised in real scheduler-shaped
workloads on top of containers-d without folding allocator research into the
measurement.
