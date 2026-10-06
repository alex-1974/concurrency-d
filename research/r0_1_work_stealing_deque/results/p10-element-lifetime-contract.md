# R0.1 P10 — Element and Lifetime Contract

## Status

    PASS

P10 qualifies the element category and lifetime model required by the selected
P08e marked-top bounded batch work-stealing deque.

The goal is to remove the accidental assumption that the queue merely stores
`size_t` values and to establish a scheduler-relevant element contract.

## P10a — Element capability matrix

The current implementation stores:

    shared T[capacity]

and uses direct atomic load/store operations on queue slots.

P10a characterizes which element categories are accepted by the current D
atomic/shared model.

Both DMD 2.111.0 and LDC 1.41.0 produced the same matrix:

    ulong
        size             = 8
        compile          = true
        elaborate copy   = false
        elaborate assign = false
        destructor       = false

    ulong*
        size             = 8
        compile          = false

    Handle64
        size             = 8
        compile          = true
        elaborate copy   = false
        elaborate assign = false
        destructor       = false

    Pair128
        size             = 16
        compile          = true
        elaborate copy   = false
        elaborate assign = false
        destructor       = false

    TaskRef128
        size             = 16
        fields           = two unshared pointers
        compile          = false

    GC class reference
        size             = 8
        compile          = false

    PostblitValue
        size             = 8
        compile          = false
        elaborate copy   = true
        elaborate assign = true

    DestructorValue
        size             = 8
        compile          = false
        destructor       = true

The relevant distinction is therefore not simply element size.

The current mechanism accepts trivial value representations but rejects
ordinary unshared pointer indirections and non-trivial lifetime-managed values.

## Shared qualification

The unshared-pointer failure is intentional D shared-safety behaviour.

Publishing:

    ulong*

into:

    shared(ulong*)

through the atomic slot operation is rejected because copying an unshared
indirection into shared storage would violate the shared type contract.

P10c demonstrated that explicit shared-compatible pointer representations are
accepted.

Both compilers qualified:

    shared(ulong)*      compile=true
    SharedPtrHandle     compile=true

where:

    struct SharedPtrHandle
    {
        shared(void)* ptr;
    }

Runtime identity tests for push, owner pop, single steal, and batch steal all
passed.

## P10b — 8-byte versus 16-byte trivial values

P10b compares:

    Handle64
        one 64-bit value

against:

    Pair128
        two 64-bit values

The 16-byte value carries an id and a deterministic guard derived from that id.
Any torn or mixed element transfer is therefore detectable.

No torn or mixed values were observed.

### DMD

    Handle64
        median = 14.468 ns/item

    Pair128
        median = 21.028 ns/item

### LDC

    Handle64
        median = 11.586 ns/item

    Pair128
        median = 18.120 ns/item

The 16-byte representation is mechanically correct, but under LDC it costs
approximately:

    +56 %

relative to the 8-byte handle in this batch-drain workload.

Therefore a two-word representation requires a concrete semantic benefit before
being chosen for the scheduler hot path.

## P10c — Preferred reference representation

P10c establishes that an explicit shared pointer may be transported directly
as an 8-byte queue element.

Both DMD and LDC qualified:

    shared(ulong)*

and:

    struct SharedPtrHandle
    {
        shared(void)* ptr;
    }

Ordinary:

    ulong*

remains rejected.

This gives the scheduler a natural representation without requiring:

- integer arena ids;
- two-word task references;
- ownership-bearing queue elements;
- GC references in the queue slot.

## P10d — Slot reuse and external lifetime

P10d qualifies a scheduler-like reference handle:

    struct TaskRef
    {
        shared(ulong)* ptr;
    }

The referenced records live outside the deque.

Configuration:

    capacity  = 4,096
    transfers = 250,000
    batch     = 8

The test therefore performs extensive physical slot reuse while every TaskRef
continues to refer to independently owned stable storage.

Both DMD and LDC passed:

- pointer identity;
- exact transfer count;
- exact global sum;
- exact XOR checksum;
- final queue accounting;
- repeated slot reuse.

### DMD

    stolen       = 250,000
    claims       = 147,898
    stolen/claim = 1.690

### LDC

    stolen       = 250,000
    claims       = 31,250
    stolen/claim = 8.000

The differing batch utilization is performance/runtime behaviour, not a
lifetime or correctness failure.

LDC remains the primary optimized-performance compiler.

## Selected element contract

The selected scheduler-neighbourhood element model is:

    trivial value handle

The preferred representation is conceptually:

    struct TaskRef
    {
        shared(TaskRecord)* ptr;
    }

The exact `TaskRecord` definition is intentionally deferred to later scheduler
research.

The deque contract does not require knowledge of the TaskRecord internals.

## Ownership contract

A `TaskRef` is:

    non-owning

The deque does not own the referenced TaskRecord.

Queue insertion does not transfer TaskRecord ownership to the deque.

Queue removal does not transfer TaskRecord ownership from the deque.

The queue merely transports a trivial handle.

## Lifetime contract

The scheduler or structured-concurrency scope owns the TaskRecord lifetime.

The required invariant is:

    every referenced TaskRecord remains alive until no queued, stolen,
    owner-local, or otherwise in-flight TaskRef can still reference it

Slot reuse does not affect TaskRecord lifetime.

Overwriting a queue slot after successful removal only removes the stored
handle value; it must not destroy or reclaim the referenced TaskRecord.

TaskRecord reclamation therefore belongs to scheduler/scope lifetime logic,
not to the deque.

## Publication contract

Publishing a TaskRef into the queue publishes only the handle.

The TaskRecord must already be initialized to the degree required by the
consumer before the TaskRef becomes visible through the queue.

The queue's existing release/acquire ordering is responsible for handle
publication ordering.

The TaskRecord's own concurrent mutation rules remain a separate scheduler
contract.

## Destruction contract

Queue operations must not invoke ownership semantics for TaskRecords.

The supported element category therefore excludes types requiring queue-slot
destruction or non-trivial transfer semantics.

The queue should not be responsible for:

- reference counting;
- GC ownership;
- postblit behaviour;
- destructors;
- task cleanup;
- result cleanup.

Those responsibilities belong above the queue layer.

## Supported category

For production-neighbourhood work, queue element types should be restricted to
trivial, atomically transportable value handles compatible with D's `shared`
model.

Required characteristics include:

- no elaborate copy constructor;
- no elaborate assignment;
- no destructor;
- no implicit ownership;
- no unshared indirection that violates shared publication;
- atomically supported slot load/store representation.

## Preferred size

The preferred scheduler handle size is:

    8 bytes

Reasons:

- directly supports shared pointer handles;
- minimal queue-slot footprint;
- lower measured transfer cost than 16-byte values;
- sufficient to reference an externally owned TaskRecord.

A 16-byte trivial value is not prohibited by the research mechanics, but it is
not preferred without a demonstrated scheduler requirement.

## Null/default value

The preferred TaskRef contract should reserve:

    null

as an invalid / empty application-level TaskRef.

Queue occupancy must continue to be determined by indices rather than by null
slot contents.

A stale physical slot value after removal therefore has no semantic meaning.

Consumers must only interpret a slot value after a successful pop or steal.

## GC interaction

GC-managed class references are not part of the selected queue element
contract.

This keeps the hot queue mechanism:

- explicit;
- deterministic;
- compatible with `@nogc` goals;
- independent of GC lifetime.

This does not prevent a TaskRecord from indirectly coordinating with
higher-level GC-managed state under a separately qualified scheduler contract.

## P10 decision

    PASS

The P10 exit criterion is satisfied:

the supported element category is explicit and no longer depends on accidental
`size_t` behaviour.

Selected production-neighbourhood direction:

    non-owning 8-byte shared-compatible TaskRef

Conceptually:

    TaskRef -> shared(TaskRecord)

The queue transports the reference.

The scheduler/scope owns the object and its lifetime.

## Deferred questions

P10 does not yet define:

- the complete TaskRecord layout;
- task state transitions;
- result storage;
- cancellation state;
- structured-concurrency scope implementation;
- TaskRecord allocator;
- reclamation strategy after task completion;
- public Task API.

Those belong to later scheduler/lifetime research.

## Next gate

Proceed to:

    P11 — Safety boundary

P11 must define how the single-owner/multi-thief contract, raw/shared atomic
internals, and callable `@safe` / `@trusted` boundary are represented without
exposing concurrency internals to queue users.
