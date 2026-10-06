# R0.1 P08d — Batch-Steal Correctness Qualification

## Status

Correctness research qualified through P08d2.

No batch mechanism from this research block is yet a production or public API
candidate.

The research establishes three distinct results:

1. naive multi-item advancement of `top` is incorrect;
2. repeated qualified single-item steals provide a correct batch semantic
   reference;
3. a multi-item claim with one `top` CAS can preserve the existing accounting
   contract when owner `pop()` and batch reservation share an additional
   coordination point.

Performance of that coordination mechanism has not yet been qualified.

## Background

P08c showed that one-owner / N-thief steal-one workloads scale poorly as
multiple thieves compete on the shared `top` CAS.

The retry curves of the D candidate and the pinned Taskflow reference were
very similar, indicating that this is primarily a steal-one contention problem
rather than a D-specific implementation defect.

Batch stealing was therefore selected as the next research direction.

## P08d0 — Naive multi-item top CAS rejection

### Candidate

The tempting design was:

    top = load(top)
    bottom = load(bottom)
    available = bottom - top
    take = min(available, requested)
    CAS(top, top + take)

This is not safe when the owner concurrently removes several elements from
`bottom`.

### Deterministic counterexample

Initial queue:

    [1 2 3 4 5 6 7 8]

Thief observes:

    top    = 0
    bottom = 8
    take   = 4

Before the thief commits, the owner pops:

    8, 7, 6, 5, 4

The owner does not need to modify `top` during those ordinary multi-item pops.

Therefore the stale thief CAS:

    CAS(top, 0, 4)

can still succeed.

Observed result under both LDC and DMD:

    owner values=8,7,6,5,4
    batch values=1,2,3,4
    duplicateCount=1
    final top=4 bottom=3

Value `4` is returned twice.

The queue has also advanced `top` beyond `bottom`.

### Conclusion

A multi-item thief cannot safely reserve a range merely by observing
`top`/`bottom` and atomically advancing `top`.

The candidate is rejected.

The P08d0 implementation remains in the research tree only as a regression
counterexample and must not be treated as a usable queue implementation.

## P08d1 — Safe semantic batch reference

### Mechanism

`stealBatch(output)` is implemented as repeated calls to the already-qualified
single-item `steal()` operation.

This deliberately performs one `top` CAS per stolen item.

It provides no CAS amortization.

Its purpose is to define a semantic reference for later optimized batch
mechanisms.

### Required semantics

A successful batch:

- returns oldest stealable values first;
- returns at most `output.length` items;
- may return a partial batch;
- never duplicates a task;
- never loses a task;
- remains correct when racing owner `pop()`;
- preserves modular counter wraparound behaviour.

### Concurrent qualification

Configuration:

- capacity: 256;
- batch size: 8;
- rounds: 500;
- thieves: 4;
- submitted: 128,000;
- every round crosses the `ulong.max -> 0` counter boundary.

LDC:

    ownerPopped=27791
    stolen=100209
    returned=128000

DMD:

    ownerPopped=47426
    stolen=80574
    returned=128000

LDC with `-preview=nosharedaccess`:

    ownerPopped=29174
    stolen=98826
    returned=128000

All variants:

    missing=0
    duplicateValues=0
    duplicateRecords=0
    outOfRange=0
    pushFailures=0
    nonEmptyAfterDrain=0
    invalidEmptyState=0

### Conclusion

Repeated qualified `steal()` is accepted as the batch semantic reference.

It is not expected to solve the P08c CAS-contention problem because it still
performs one claim per item.

## P08d2 — Coordinated single-CAS batch claim

### Problem to solve

P08d0 proves that a batch thief cannot independently establish:

    top unchanged

and:

    bottom still leaves the full requested range stealable

using only separate `top` and `bottom` observations.

A safe multi-item claim therefore requires additional coordination or a
different atomic state representation.

### Research mechanism

P08d2 introduces a narrow internal `_batchClaimGate`.

The layout continues to preserve the previously qualified relevant offsets:

    top       +0x00
    bottom    +0x40
    buffer    +0x80

The gate consumes existing padding.

Behaviour:

- `tryPush()` remains gate-free;
- ordinary `steal()` remains gate-free;
- owner `pop()` briefly acquires the gate;
- `stealBatch()` acquires the same gate;
- a batch thief reads candidate slots while they are still protected by the
  current `top`;
- one CAS advances `top` by the entire batch size;
- ordinary single thieves may still race through `top`; if one wins first, the
  batch CAS fails.

The gate prevents the P08d0 owner-pop overlap while the multi-item claim is
formed.

### Qualification

Configuration:

- capacity: 256;
- batch size: 8;
- rounds: 500;
- thieves: 4;
- submitted: 128,000;
- modular wraparound exercised every round.

LDC:

    ownerPopped=3043
    stolen=124957
    returned=128000
    successfulBatches=15776
    partialBatches=324

DMD:

    ownerPopped=9189
    stolen=118811
    returned=128000
    successfulBatches=15056
    partialBatches=413

LDC with `-preview=nosharedaccess`:

    ownerPopped=2289
    stolen=125711
    returned=128000
    successfulBatches=15863
    partialBatches=345

All variants:

    missing=0
    duplicateValues=0
    duplicateRecords=0
    outOfRange=0
    pushFailures=0
    nonEmptyAfterDrain=0
    invalidEmptyState=0

All active configurations exercised successful and partial batch paths.

### Code-generation control

Optimized LDC output contains:

- locked compare-and-swap operations for the coordination gate;
- the established locked RMW barrier form;
- locked compare-and-swap on the queue claim state.

This is only a code-generation observation, not yet a performance conclusion.

## Interpretation

P08d0 rules out the simplest multi-item `top` CAS design.

P08d1 gives the research program a correct batch semantic oracle.

P08d2 demonstrates that a real multi-item claim with one `top` CAS can satisfy
the current R0.1 accounting and wraparound contract when owner pop participates
in a shared coordination mechanism.

This does not yet establish that the mechanism is desirable.

The new gate adds synchronization to every owner `pop()` even when batch
stealing is rare. That cost could erase the benefit of reducing thief-side CAS
frequency.

## Next qualification

The next probe must measure the cost-benefit relationship directly.

Compare:

1. current padded RMW steal-one candidate;
2. P08d1 repeated-steal batch reference;
3. P08d2 coordinated single-CAS batch.

Measure batch sizes:

    1, 2, 4, 8, 16, 32

and thief counts:

    1, 2, 4, 8

Primary metrics:

- ns/item;
- tasks/s;
- successful batch claims;
- average tasks per successful batch;
- top-CAS attempts per transferred item;
- gate acquisition attempts / contention;
- owner push retries;
- empty batch attempts.

The performance probe must retain fixed thread affinity and the same accounting
checksum discipline established by P08/P08c.

Only after that measurement should the coordination mechanism be retained,
rejected, or replaced by a different packed-state design.
