# R0.1 P08e — Marked-Top Batch-Steal Qualification

## Status

Research candidate qualified through P08e5.

The marked-top design is the strongest batch-steal candidate observed so far.

It is not yet a production decision.

Open qualification items remain:

- the current prototype uses a 63-bit modular counter domain rather than the
  previously qualified full 64-bit domain;
- weak-memory / non-x86 ordering has not yet been qualified;
- scheduler-level integration and victim-selection policy remain outside this
  probe block.

## Motivation

P08d established two important results:

1. multi-item claims can substantially amortize thief-side CAS traffic;
2. serializing owner `pop()` and batch thieves through a shared gate destroys
   mixed-workload performance.

The required architecture therefore needs to:

- reserve multiple top items atomically;
- prevent the P08d0 owner/batch overlap;
- avoid an unconditional owner-side lock/CAS in the normal pop path.

## Design

P08e stores the top position together with a batch-in-progress marker.

Research encoding:

    bits 63..1  63-bit modular top counter
    bit 0       batch-busy marker

A batch thief:

1. CASes `(top, idle)` to `(top, busy)`;
2. observes bottom while top is marked;
3. copies the selected oldest items;
4. publishes `(top + N, idle)`.

During the marked interval:

- ordinary thieves cannot claim top;
- owner `pop()` that reaches the top observation sees `busy`;
- the owner restores its speculative bottom decrement and retries;
- `tryPush()` remains free of the batch gate.

The normal uncontended owner path performs no additional CAS solely for batch
coordination.

## P08e0 — Sequential and modular semantics

Qualified under:

- LDC 1.41.0;
- DMD 2.111.0;
- LDC with `-preview=nosharedaccess`.

Observed:

    batch=1,2,3,4
    owner=8,7,6,5
    wrap finalTop=1 finalBottom=1

Result:

- oldest-first batch ordering preserved;
- owner LIFO ordering preserved;
- no owner/batch overlap;
- 63-bit modular wrap preserved;
- canonical empty state restored.

## P08e1 — Forced overlap and concurrent wrap stress

### Forced P08d0-style race

The research probe deliberately pauses a thief after publishing the busy
marker and starts the owner while the batch is still in progress.

Observed owner busy-path executions:

    LDC       busyRetries=13
    DMD       busyRetries=12
    LDC noshared busyRetries=7

Therefore the owner was demonstrably active inside the marked interval.

Observed result in all cases:

    batch = 1,2,3,4
    owner = 8

No duplicate occurred.

### Multi-thief wrap stress

Configuration:

- 500 rounds;
- capacity 256;
- 4 thieves;
- batch size 8;
- 128,000 submitted items;
- every round crosses the 63-bit modular wrap boundary.

All compiler modes produced:

    missing=0
    duplicateValues=0
    duplicateRecords=0
    outOfRange=0
    pushFailures=0
    nonEmptyAfterDrain=0
    invalidEmptyState=0
    leakedBusy=0

The marked-top candidate therefore survives the previously rejected overlap
shape and concurrent modular stress.

## P08e2 — Uncontended owner hot path

Compared:

- padded RMW baseline;
- P08d safe reference;
- rejected P08d gated candidate;
- P08e marked-top.

### Pop-many

Run 1:

    baseline     6.077 ns/op
    safe-ref     6.001 ns/op
    gated       11.051 ns/op
    marked-top   6.150 ns/op

Run 2:

    baseline     6.151 ns/op
    safe-ref     6.133 ns/op
    gated       11.035 ns/op
    marked-top   5.998 ns/op

Marked-top is effectively at baseline for the owner-only pop path.

### Push-pop pair

Run 1:

    baseline    14.039 ns/op
    safe-ref    13.742 ns/op
    gated       18.619 ns/op
    marked-top  14.444 ns/op

Run 2:

    baseline    13.806 ns/op
    safe-ref    13.837 ns/op
    gated       19.262 ns/op
    marked-top  14.929 ns/op

Marked-top retains a near-baseline owner hot path and clearly avoids the P08d
gate penalty.

## P08e3 — Concurrent owner/thief drain

Configuration:

- prefilled queue;
- 1,048,576 items;
- owner CPU 2;
- 4 thieves;
- batch size 8;
- 4 warmups;
- 15 measured samples.

### Baselines

Steal-one:

    61.403 ns/item
    60.845 ns/item

Repeated-steal:

    60.654 ns/item
    61.343 ns/item

Rejected shared gate:

    302.154 ns/item
    180.858 ns/item

### Marked-top

Run 1:

    median = 13.959 ns/item
    p10/p90 = 9.797 / 14.265
    stolen/claim = 8.000

Run 2:

    median = 14.144 ns/item
    p10/p90 = 10.684 / 15.110
    stolen/claim = 8.000

This is approximately 4.3x faster than steal-one in this workload.

Unlike the shared-gate candidate, marked-top does not show the same extreme
latency collapse.

### Owner share observation

The synthetic pure-drain workload strongly favors batch thieves.

Across 15 samples marked-top returned only about 2–3 percent of tasks through
the owner.

This triggered additional scheduler-like qualification rather than being
silently accepted as a desirable scheduler property.

## P08e4 — Victim-drain scaling

Corrected measurements reset the research busy-retry counter for every
benchmark run.

### One thief

    median = 9.423 / 9.512 ns/item
    ownerShare = 1.554 / 1.534 %
    stolen/claim = 8.000

### Two thieves

    median = 12.490 / 12.955 ns/item
    ownerShare = 1.551 / 1.373 %
    stolen/claim = 8.000

### Four thieves

    median = 16.153 / 16.651 ns/item
    ownerShare = 1.127 / 1.294 %
    stolen/claim = 8.000

### Eight thieves

    median = 16.265 / 18.003 ns/item
    ownerShare = 0.933 / 1.199 %
    stolen/claim = 8.000

### Interpretation

Adding thieves does not make a single victim drain faster.

One thief already exploits almost the complete batch-transfer opportunity.

Additional thieves primarily add contention for the victim's marked top.

This is consistent with the intended scheduler interpretation:

> A successful thief should transfer a useful amount of work and then process
> or enqueue that work locally rather than immediately attack the same victim
> again.

The 8-thief case also introduces SMT and therefore remains a secondary
scaling data point.

## P08e5 — Scheduler-like local work

P08e5 adds deterministic work after every transferred task.

A batch thief processes the complete stolen batch before returning to the
victim.

This more closely models:

    steal -> local work -> steal again

than the pure-drain probes.

Configuration:

- 1,048,576 tasks;
- 4 thieves;
- batch size 8;
- work rounds 0, 16 and 64;
- exact value and work checksums.

### No payload work

Steal-one:

    61.809 / 60.938 ns/item
    ownerShare = 49.396 / 50.272 %

Marked-top:

    16.333 / 16.671 ns/item
    ownerShare = 1.413 / 1.363 %
    stolen/claim = 8.000

Marked-top speedup:

    approximately 3.65x to 3.78x

### Work = 16

Steal-one:

    67.271 / 66.206 ns/item
    ownerShare = 47.026 / 47.770 %

Marked-top:

    17.755 / 17.906 ns/item
    ownerShare = 7.042 / 7.042 %
    stolen/claim = 8.000

Marked-top speedup:

    approximately 3.70x to 3.79x

### Work = 64

Steal-one:

    69.771 / 68.441 ns/item
    ownerShare = 29.291 / 29.322 %

Marked-top:

    32.656 / 32.552 ns/item
    ownerShare = 19.067 / 19.042 %
    stolen/claim = 8.000

Marked-top speedup:

    approximately 2.10x to 2.14x

### Busy contention trend

Marked-top aggregate owner busy retries across the measured samples decline as
local work increases:

    work 0   approximately 1.76–1.83 million
    work 16  approximately 1.36–1.39 million
    work 64  approximately 0.19–0.21 million

This supports the interpretation that the extreme owner suppression in the
pure-drain tests is substantially driven by immediate repeated stealing from
the same victim.

It does not prove a general fairness guarantee.

## Current conclusion

Marked-top is the first R0.1 batch candidate that simultaneously demonstrates:

- protection against the P08d0 multi-item overlap;
- successful multi-item claim amortization;
- exact batch width 8 under the tested workloads;
- near-baseline owner-only hot-path performance;
- strong concurrent owner/thief throughput;
- correct modular accounting under the current 63-bit counter model;
- correct LDC, DMD and `-preview=nosharedaccess` qualification for the
  correctness probes.

The performance evidence strongly supports continued qualification.

It does not yet justify production promotion.

## Important limitations

### 63-bit counter domain

The busy marker currently consumes one bit from the top state.

The prototype therefore uses a 63-bit modular counter domain.

This is a deliberate research simplification.

Before production selection, determine whether:

- 63 bits is an acceptable formal domain;
- a different encoding can retain the full 64-bit domain;
- a versioned/wider state is preferable;
- architecture-specific wider atomics are justified.

### Weak-memory architecture

The current high-performance evidence is from x86_64 / Skylake.

The memory-ordering argument for the new two-phase marked state must be
reviewed explicitly before non-x86 claims are made.

### Scheduler policy

Raw repeated stealing from one victim is intentionally adversarial.

Production victim-selection and local-work policy must prevent workers from
hammering one victim when useful local work has already been acquired.

Fairness and local-owner progress are scheduler-policy questions in addition
to deque-mechanism questions.

## Next qualification

Before choosing marked-top as the preferred R0.1 design:

1. document the exact happens-before argument for:
   - busy publication;
   - owner rollback;
   - batch slot reads;
   - new-top publication;
   - push slot reuse;
2. qualify the ordering on at least one weak-memory target or through a
   suitable formal/litmus-model route;
3. resolve the 63-bit versus full-64-bit counter contract;
4. then repeat external C++ parity controls for the qualified mechanism.

