# R0.2 P01 — Task-reference representation capability

Status: PASS

## Goal

Determine which candidate TaskRef layouts are mechanically valid
`containers-d WorkStealingDeque` elements on the baseline compilers and on
native AArch64.

## Qualified platforms

- DMD 2.111.0 / Linux x86_64
- LDC 1.41.0 / Linux x86_64
- LDC 1.41.0 / native Linux AArch64 / ARM Neoverse-N2

All three produced the same representation matrix.

## Matrix

| Representation | Size | Align | Queue compatible | Elaborate copy | Elaborate assign | Destructor |
|---|---:|---:|---|---|---|---|
| PointerOnlyRef | 8 | 8 | yes | no | no | no |
| PointerExecuteRef | 16 | 8 | yes | no | no | no |
| TwoSharedPointersRef | 16 | 8 | yes | no | no | no |
| TaggedPointerRef | 16 | 8 | yes | no | no | no |
| ExecuteFn | 8 | 8 | n/a | n/a | n/a | n/a |

## Findings

### Pointer-only baseline remains valid

The R0.1 preferred representation remains mechanically ideal:

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
}
```

It is:

- one machine word;
- queue-compatible;
- trivially transferable;
- null-default;
- accepted identically by DMD and LDC;
- accepted on native AArch64.

### Pointer + execute function remains a live candidate

Contrary to a possible shared-publication concern, the two-word form:

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}
```

is accepted by `WorkStealingDeque` on all qualified configurations.

It therefore proceeds to P02.

However, it starts P02 with an existing cost burden:

- 16-byte queue element;
- R0.1 P10 measured approximately +56% transfer cost for a generic 16-byte
  trivial element versus an 8-byte handle in the LDC batch-drain workload.

A dispatch advantage must be large enough to overcome that scheduler-level
transport cost before this form can be selected.

### Inline discriminator does not stay compact

A naïve:

```d
struct TaggedPointerRef
{
    shared(TaskRecord)* ptr;
    ubyte kind;
}
```

is 16 bytes because of alignment/padding.

Therefore R0.2 will not treat a tag placed beside the pointer as a compact
queue representation.

A D-native discriminator candidate should instead keep the queue handle at
8 bytes and store immutable dispatch metadata in the referenced TaskRecord.

## Decision

P01 does not select the final TaskRef.

Candidates proceeding to P02:

1. 8-byte pointer-only with record-stored execute metadata;
2. 16-byte pointer + execute function;
3. 8-byte pointer-only with compact record discriminator.

Rejected as a useful distinct hot-path layout:

- pointer + inline byte discriminator, because it occupies 16 bytes without
  carrying the direct execute target.

## Next gate

P02 — dispatch kernel.

P02 must measure dispatch separately from allocation and queue contention,
then later results must still be reconciled with the known queue-transfer cost.
