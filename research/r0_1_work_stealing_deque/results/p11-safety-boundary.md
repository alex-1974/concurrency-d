# R0.1 P11 — Safety Boundary

## Status

    PASS

P11 defines the smallest unsafe implementation boundary for the selected P08e
marked-top bounded batch work-stealing deque and establishes the callable
contract above it.

The safety work deliberately does not change the queue algorithm, memory
ordering, batching protocol, or ownership model.

## Initial audit

P11a audited the unmodified selected candidate with the P10 TaskRef model:

    struct TaskRef
    {
        shared(ulong)* ptr;
    }

Both DMD 2.111.0 and LDC 1.41.0 reported the same initial result:

    safe tryPush       = true
    safe pop           = false
    safe steal         = false
    safe stealBatch    = false
    safe snapshots     = true

    value copy         = true
    assignment         = true
    pass by value      = true
    return by value    = true

This exposed two independent production-neighbourhood issues:

1. removal paths were inferred as `@system`;
2. the concurrent queue state was freely copyable.

## Unsafe-path diagnosis

Direct compiler diagnostics for:

    pop
    steal
    stealBatch

identified the same cause on DMD and LDC:

    researchSeqCstBarrier

The removal methods themselves were not independently rejected for their
ordinary atomic slot operations.

The helper is:

    private void researchSeqCstBarrier(
        shared int* fenceWord)

Its purpose is restricted to the ordering primitive needed by the selected
P08e algorithm.

On LDC/x86_64 it performs:

    atomicFetchAdd!(MemoryOrder.seq)(
        *fenceWord,
        0);

as the compact sequentially-consistent barrier selected during the earlier
code-generation research.

On other paths it falls back to:

    atomicFence!(MemoryOrder.seq)();

The helper:

- receives only the address of the queue's internal fence word;
- does not expose that pointer;
- does not access task payload storage;
- does not return references;
- does not manage lifetime;
- exists solely to perform the qualified ordering primitive.

It is therefore the smallest reviewable trusted boundary identified by the
audit.

## Selected trusted boundary

The helper is explicitly:

    @trusted @nogc nothrow

No complete queue operation is marked `@trusted`.

The callable queue operations are explicitly:

    @safe @nogc nothrow

for:

    tryPush
    pop
    steal
    stealBatch
    sizeSnapshot
    emptySnapshot

This keeps low-level trust local rather than promoting whole concurrent
operations into the trusted surface.

## Queue identity

Concurrent queue state has identity.

Copying:

- top state;
- bottom state;
- fence state;
- buffer slots;

would create a second synchronization object with copied state but no valid
relationship to the original queue.

The selected candidate therefore declares:

    @disable this(this);

After this change both DMD and LDC report:

    value copy         = false
    assignment         = false
    pass by value      = false
    return by value    = true

The remaining fresh return-by-value support is intentional.

A newly constructed queue may be returned to its final storage location using
D move/NRVO semantics.

What is prohibited is duplication of an already existing queue identity.

## Hardened compile-time contract

P11b verifies on both DMD and LDC:

    complete API @safe       = true
    copy construction reject = true
    assignment reject        = true
    pass-by-value reject     = true
    fresh return allowed     = true
    @safe round trip         = true

All checks pass.

## TaskRef lifetime interaction

An initial `@safe` round-trip probe attempted to construct a TaskRef from the
address of a stack-local variable.

Both compilers correctly rejected this:

    taking the address of stack-allocated local variable
    is not allowed in a @safe function

This was not a queue failure.

It demonstrates a useful interaction with the P10 lifetime contract.

The corrected probe uses persistent shared storage, representing the required
scheduler/scope-owned TaskRecord lifetime.

That version passes entirely from `@safe` code.

Therefore P11 reinforces the P10 rule:

    the referenced TaskRecord must outlive every queued or in-flight TaskRef

and `@safe` prevents at least some invalid short-lived-reference construction
patterns automatically.

## Memory safety versus protocol safety

P11 distinguishes two separate concepts.

### Memory safety

The normal callable queue surface is `@safe`.

Users of the primitive do not need to perform:

- raw pointer manipulation;
- direct fence-word access;
- manual atomic CAS;
- manual top-state encoding;
- unsafe buffer publication.

Those details remain inside the implementation.

### Protocol safety

The central work-stealing precondition remains:

    exactly one owner
    zero or more thieves

Only the owner may perform owner-side operations:

    tryPush
    pop

Thieves may perform:

    steal
    stealBatch

D's `@safe` attribute does not prove this scheduling protocol.

Calling owner operations concurrently from multiple owner threads may violate
the deque algorithm even though the call itself is memory-safe in the D
language sense.

This remains a documented concurrency precondition and should later be made
difficult to violate by scheduler worker ownership and API structure.

P11 does not claim otherwise.

## Negative qualification

The P11 audit confirms rejection of:

    copy construction
    assignment
    pass-by-value duplication

Existing template guards continue to reject:

    LogSize = 0
    LogSize >= 62

P10 already rejects unsupported element categories such as:

- unshared pointer elements;
- GC class references;
- elaborate-copy/postblit values;
- destructor-owning values.

Together these form the current negative contract around the internal
primitive.

## Regression qualification

The safety hardening was tested against previously qualified P09 and P10
workloads.

No algorithm or memory-order change was made.

### P09a bounded occupancy

Both DMD and LDC pass all occupancy levels and full-queue transitions.

LDC P08e medians after safety hardening:

    12.5%      6.312 ns/pair
    25.0%      6.138 ns/pair
    50.0%      6.133 ns/pair
    75.0%      6.157 ns/pair
    capacity-1 6.214 ns/pair
    capacity   6.195 ns/pair

These remain in the previously qualified performance range.

### P09b concurrent near-capacity refill

Both compilers pass exact accounting and checksum validation.

LDC P08e:

    median       = 6.099 ns/transfer
    stolen/claim = 8.000

No safety-related hot-path regression is visible.

### P10b trivial element transfer

Both 8-byte and 16-byte trivial-value tests remain correct.

LDC:

    Handle64 = 11.359 ns/item
    Pair128  = 18.585 ns/item

The previously observed preference for the 8-byte representation remains.

### P10d shared TaskRef slot reuse

Both compilers pass:

- exact transfer count;
- pointer identity;
- exact sum;
- exact XOR;
- repeated slot reuse.

LDC again obtains:

    stolen/claim = 8.000

## Scheduler-like regression

P08e5 was rerun after the safety changes.

Configuration:

    items    = 1,048,576
    thieves  = 4
    batch    = 8
    warmups  = 4
    samples  = 15

LDC marked-top results:

    work=0
        median       = 16.727 ns/item
        stolen/claim = 8.000

    work=16
        median       = 17.842 ns/item
        stolen/claim = 8.000

    work=64
        median       = 33.675 ns/item
        stolen/claim = 8.000

All correctness checksums match.

These values remain consistent with the previously qualified scheduler-like
performance class.

There is no evidence of a material performance regression caused by:

- explicit `@safe` annotations;
- the narrow `@trusted` barrier helper;
- disabled queue copying.

## Selected P11 contract

The production-neighbourhood safety model is:

    caller
      |
      v
    @safe queue API
      |
      +-- tryPush
      +-- pop
      +-- steal
      +-- stealBatch
      +-- snapshots
      |
      v
    private implementation
      |
      v
    researchSeqCstBarrier
        @trusted
      |
      v
    low-level SC atomic/fence operation

The queue itself is non-copyable.

TaskRef remains a non-owning shared-compatible value handle.

TaskRecord lifetime remains external to the queue.

## P11 decision

    PASS

P11 exit criteria are satisfied:

- users of the internal primitive do not need raw atomics or pointer
  manipulation;
- the trusted implementation boundary is small and explicit;
- concurrent queue identity cannot be duplicated accidentally;
- callable operations are explicitly `@safe`;
- element lifetime remains governed by the P10 contract;
- owner/thief protocol requirements are explicitly separated from language
  memory safety;
- previous correctness and performance evidence remains valid.

## Deferred safety work

P11 does not yet define:

- public Executor or Task API;
- worker ownership types;
- static enforcement of owner-only operations;
- TaskRecord state-machine safety;
- cancellation safety;
- result lifetime;
- allocator/reclamation safety.

Those belong to later scheduler and structured-concurrency work.

## Next gate

Proceed to:

    P12 — Bounded-overflow policy

P12 must decide scheduler behaviour when a worker-local bounded deque is full.

The local deque itself remains bounded.

Do not introduce resizing merely to avoid defining overflow policy.
