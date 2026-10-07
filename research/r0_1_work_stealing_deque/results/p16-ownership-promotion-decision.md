# P16 — Ownership and Promotion Decision

Status: DECISION RECORDED

## Decision

    PROMOTE TO containers-d

The qualified R0.1 work-stealing deque has a coherent container-domain
contract that is independent of concurrency-d scheduler policy.

Promotion means ownership of the reusable concurrent container primitive
belongs in containers-d.

It does not mean concurrency-d should immediately depend on an unqualified or
unfinished containers-d implementation. API and implementation promotion must
still preserve the qualified R0.1 contract and evidence.

## Gate prerequisites

The promotion decision is made after:

- P09 PASS — bounded occupancy and near-capacity behavior;
- P10 PASS — element and lifetime contract;
- P11 PASS — safety boundary;
- P12 PASS — explicit scheduler overflow policy separated from the deque;
- P13 PASS — minimal scheduler-neighborhood qualification;
- P14 PASS — end-to-end scheduler workloads and Taskflow controls;
- P15 PASS — native AArch64 runtime qualification.

The selected candidate is therefore no longer supported only by isolated
microbenchmarks or x86_64 evidence.

## Candidate shape

Selected research type:

    MarkedTopBatchBoundedWorkStealingDeque!(T, LogSize)

The core queue contract is:

- generic element type subject to an explicit transport contract;
- fixed power-of-two capacity;
- exactly one owner;
- zero or more thieves;
- owner operations:
  - tryPush
  - pop
- thief-safe operations:
  - steal
  - stealBatch
- bounded non-resizing storage;
- explicit full result through tryPush == false;
- no scheduler action on overflow;
- non-copyable concurrent identity;
- @safe callable surface;
- narrow internal @trusted ordering primitive;
- @nogc / nothrow operations;
- documented memory-ordering protocol.

## P16 Candidate A criteria

### Generic element contract

PASS.

P10 establishes that the queue is not restricted to size_t or TaskRef.

The selected supported category is:

    trivial, atomically transportable value handle
    compatible with D shared publication

The implementation accepts trivial representations including:

- ulong;
- 64-bit trivial handles;
- 128-bit trivial pairs;
- explicit shared-compatible pointer handles.

It rejects unsupported ownership-bearing or non-trivial representations such
as:

- elaborate-copy/postblit values;
- destructor-owning values;
- GC class references;
- ordinary unshared pointer indirections that violate shared publication.

The production container API must encode or document this capability boundary
rather than pretending to support arbitrary T.

### Clear lifetime semantics

PASS.

The deque transports values; it does not own external objects referenced by
those values.

For reference handles:

- insertion does not transfer pointee ownership;
- removal does not transfer pointee ownership;
- referenced storage must outlive every queued or in-flight handle;
- reclamation belongs to the caller/consumer layer.

This is a generic container lifetime rule, not a Task scheduler rule.

### Reusable single-owner / multi-thief contract

PASS.

P11 separates language memory safety from protocol safety.

The concurrency precondition is generic:

    exactly one owner
    zero or more thieves

Only the owner performs:

- tryPush;
- pop.

Thieves perform:

- steal;
- stealBatch.

No concurrency-d Worker or Executor type is required to state this contract.

### Capacity semantics independent of scheduler policy

PASS.

P09 qualifies bounded fixed-capacity behavior.

P12 explicitly establishes that:

    tryPush(item) == false

is the deque's complete full-capacity result.

The selected execute-inline response belongs to concurrency-d scheduler policy
and is not implemented by the deque.

The deque therefore remains:

- bounded;
- fixed-capacity;
- non-resizing;
- policy-independent.

### Generic batch semantics

PASS.

stealBatch operates on T values through a caller-provided output slice.

The queue has no knowledge of:

- TaskRef semantics;
- task execution;
- worker ownership beyond owner/thief operation rights;
- scheduler batch consumption strategy.

The marked-top protocol protects generic slot transfer and owner overlap.

### Documented memory-ordering contract

PASS for promotion ownership.

The selected candidate has qualified ordering through:

- targeted D atomic implementation;
- x86_64 code-generation analysis;
- AArch64 code-generation analysis;
- formal/litmus evidence;
- forced owner/batch overlap tests;
- x86_64 runtime qualification;
- native AArch64 runtime qualification.

The exact production documentation should be moved with the algorithm rather
than reconstructed from scratch in containers-d.

### Safe reusable boundary

PASS.

P11 establishes:

- normal callable queue operations are @safe;
- the queue is non-copyable;
- the low-level sequentially-consistent barrier helper is the narrow @trusted
  boundary;
- users do not perform raw atomic or pointer manipulation.

The owner/thief protocol remains a documented concurrency precondition.

### No dependency on concurrency-d task lifecycle

PASS.

The candidate module itself contains no dependency on:

- Task;
- TaskRef;
- TaskRecord;
- Scheduler;
- Worker;
- Executor;
- task scopes;
- structured concurrency;
- cancellation;
- parking/wake policy;
- task-state transitions;
- overflow execution policy.

TaskRef was one qualified consumer representation, not part of the deque
algorithm.

## Candidate B rejection

The evidence does not support keeping the deque internal merely because
concurrency-d is its first consumer.

The selected mechanics do not materially depend on:

- scheduler-owned lifetime;
- TaskRef;
- worker-local task-state invariants;
- executor coordination;
- execute-inline overflow;
- scheduler-specific batch semantics.

Those concerns remain above the deque boundary.

Therefore:

    KEEP INTERNAL TO concurrency-d

is rejected as the ownership decision.

## Important promotion constraints

Promotion must not mechanically copy a research module and declare it public.

containers-d production work must preserve the qualified semantics while
performing its own repository-specific API and release work.

In particular:

1. the public type name is still a containers-d API decision;
2. the generic T capability constraint must be explicit;
3. owner-only versus thief-safe operations must be clearly documented;
4. fixed/runtime capacity family decisions remain containers-d design work;
5. the 63-bit marked-top counter domain must become an explicit production
   contract or be replaced by a separately qualified representation;
6. cache-line layout must remain evidence-driven;
7. @safe/@trusted/@nogc/nothrow claims must be retained and requalified;
8. native x86_64 and AArch64 evidence must travel with the promoted algorithm;
9. concurrency-d must not depend on the promoted implementation until the
   containers-d version reproduces the required contract and quality gates.

## Repository ownership

Decision:

    containers-d owns the reusable work-stealing deque container family.

concurrency-d owns:

- scheduler policy;
- TaskRef/TaskRecord definitions;
- TaskRecord lifetime/reclamation;
- worker topology;
- victim selection;
- when to use single versus batch stealing;
- execute-inline overflow policy;
- executor coordination;
- parking/wake behavior;
- structured-concurrency behavior.

This boundary avoids both duplication and scheduler leakage into the container
library.

## Required cross-repository follow-up

The existing containers-d ownership tracker is:

    alex-1974/containers-d issue #37
    "Research concurrent work-stealing deque for concurrency-d"

P16 requires that tracker to be updated with:

- P09–P15 evidence;
- accepted P08e marked-top candidate;
- rejected alternatives where relevant;
- native AArch64 result;
- this explicit promotion decision;
- a separate follow-up for containers-d implementation/API work.

No concurrency-d -> containers-d dependency should be introduced until the
promoted containers-d implementation passes its own production qualification.

## Exit status

Decision produced:

    PROMOTE TO containers-d

The decision portion of P16 is complete.

The remaining required P16 action is the cross-repository update of
containers-d issue #37.
