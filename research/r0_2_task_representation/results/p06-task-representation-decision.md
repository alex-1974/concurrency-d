# R0.2 P06 — Task representation decision

Status: PASS

## Decision

Select the following internal representation for R0.3 worker-scheduling
research:

```d
struct TaskRef
{
    shared(TaskHeader)* ptr;
}

struct TaskHeader
{
    ExecuteFn execute;
}
```

On the qualified 64-bit targets:

```text
TaskRef    = 8 bytes
TaskHeader = 8 bytes
```

TaskRef is non-owning.

The TaskRecord is externally owned by the lifetime regime that created it.

## Why this representation

### Queue footprint

The hot queue element remains one machine word.

This preserves the strongest result carried forward from R0.1 and avoids the
known transport cost of wider queue elements.

### Open-world dispatch

The execute target lives in the TaskRecord header.

This supports an open set of user task types without requiring a global closed
discriminator registry.

### Safe publication

The header is initialized before TaskRef publication.

Scheduler dispatch reads the execute target from shared metadata using the
qualified safe path.

### Lifetime flexibility

The same TaskRef representation supports:

- stack-resident structured tasks;
- externally owned stable records;
- future pooled records.

Stack-resident records are valid only under the structured rule:

```text
all queued, stolen, executing and otherwise in-flight TaskRefs complete
before the owning stack frame returns
```

DIP1000 rejects direct stack escape in the qualified negative case.

### Minimal universal header

Only the execute target is universal scheduler metadata.

Do not add speculative universal fields for:

- cancellation;
- result storage;
- TaskScope;
- allocator/pool bookkeeping;
- future task state.

Those fields require their own evidence.

## Rejected alternatives

### Pointer + execute target in TaskRef

Rejected.

Reasons:

- 16-byte queue element;
- already-known queue transfer penalty;
- optimized runtime transport failure under LDC when the representation is
  only 8-byte aligned;
- explicit 16-byte alignment fixes the mechanical failure but not the footprint
  disadvantage;
- no end-to-end benefit justified the larger hot queue element.

### Pointer + inline discriminator

Rejected as a hot layout.

A pointer plus byte discriminator still occupies 16 bytes because of
alignment/padding.

### Pointer-only + record discriminator

Not selected as the general representation.

A closed-world discriminator can be very fast, especially on AArch64, but it
does not represent the open set of task types required by a general-purpose
library.

It remains available as a possible later specialization for bounded internal
task families.

### Claimed-record unshared execution shortcut

Rejected.

The focused P05d diagnostic showed no consistent LDC benefit:

- hosted x86_64 became worse in important cases;
- native AArch64 was effectively unchanged.

The ordinary safe shared metadata path is retained.

## Scheduler-neighborhood qualification

P05 passed on:

- DMD 2.111 / x86_64;
- LDC 1.41 / x86_64;
- native AArch64 / LDC 1.41 / Neoverse-N2;
- local project XPS / LDC 1.41.

Qualified workloads:

- flat fine/medium/coarse;
- recursive fork/join;
- irregular graph;
- single stealing;
- batch stealing;
- bounded queues;
- P12 execute-inline overflow behavior.

## Performance interpretation

The representation has a measurable cost relative to synthetic R0.1 packed
value handles in the smallest recursive workload.

That cost is retained explicitly.

The R0.1 recursive baseline embeds synthetic id/depth metadata directly in the
8-byte queue element and executes work directly. It therefore does not provide
the same task-record semantics as the selected general-purpose representation.

The local XPS irregular workload showed no representation regression:

```text
R0.2 TaskRef:
  single 42.397 ns/task
  batch  42.085 ns/task
```

The native AArch64 irregular workload was also effectively at R0.1 parity.

The selected form is therefore accepted as the best qualified general-purpose
representation, not as a claim that pointer-based task records are cost-free.

Further scheduling-policy optimization belongs to R0.3.

## Ownership and lifetime contract

TaskRef owns nothing.

TaskRecord storage may be supplied by:

- a structured stack scope;
- an external stable owner;
- a future allocator/pool.

The owner is responsible for keeping the TaskRecord alive until no queued,
stolen, executing or otherwise in-flight TaskRef can reference it.

The work-stealing deque transports TaskRef values but does not reclaim records.

## Type erasure

The scheduler sees only TaskHeader.

A generated type-specific execution thunk may recover the concrete record from
the first-field TaskHeader.

That downcast is the narrow type-erasure boundary.

Normal scheduler dispatch remains safe.

## Deferred decisions

Explicitly deferred:

- allocator/pool implementation -> R0.5;
- TaskScope implementation -> R1;
- cancellation state -> R1;
- typed result storage -> R1;
- public Task API -> R1;
- parking/wake -> R0.4;
- worker victim/search policy -> R0.3.

## R0.2 exit status

The R0.2 exit criteria are satisfied:

- explicit layout: PASS;
- explicit lifetime contract: PASS;
- containers-d queue compatibility: PASS;
- dispatch evidence: PASS;
- scheduler-neighborhood evidence: PASS;
- DMD/LDC qualification: PASS;
- native AArch64 coverage: PASS;
- local native x86_64/XPS qualification: PASS;
- allocation/ownership questions clearly deferred: PASS.

Result:

```text
R0.2 TASK REPRESENTATION: PASS
```

## Next research gate

R0.3 — Worker scheduling.

R0.3 may now compare:

- sticky versus random victim selection;
- bounded searching-worker counts;
- continuation/direct-execution fast paths.

The selected TaskRef/TaskHeader contract should be treated as the internal
research baseline unless new contradictory evidence appears.
