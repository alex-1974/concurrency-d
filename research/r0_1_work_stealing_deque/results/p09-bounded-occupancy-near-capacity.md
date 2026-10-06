# R0.1 P09 — Bounded Occupancy and Near-Capacity Qualification

## Status

    PASS

P09 qualifies the selected P08e marked-top bounded batch work-stealing deque
for bounded occupancy, full-capacity transitions, and concurrent slot reuse
near capacity.

Two probes were used:

    P09a — owner-only stable occupancy and capacity transitions
    P09b — concurrent thief removal and owner refill while near full

The modular single-steal deque is retained as the control.

Primary optimized performance compiler:

    LDC 1.41.0 / LLVM 19

Correctness comparison compiler:

    DMD 2.111.0

## P09a — Stable occupancy and capacity transitions

Configuration:

    capacity   = 65,536
    operations = 8,000,000
    warmups    = 5
    samples    = 21

Occupancies:

    12.5 %
    25 %
    50 %
    75 %
    capacity - 1
    capacity

Both implementations passed the explicit transition:

    fill to capacity
    failed push while full
    pop one item
    successful recovery push
    full again
    failed push while full

No live item was overwritten and the queue returned the expected size after
every transition.

### LDC results

Single-steal control:

    occupancy      median ns/pair

    12.5 %             5.919
    25.0 %             5.899
    50.0 %             5.910
    75.0 %             5.887
    capacity - 1       5.910
    capacity           5.898

P08e:

    occupancy      median ns/pair

    12.5 %             6.139
    25.0 %             6.162
    50.0 %             6.149
    75.0 %             6.138
    capacity - 1       6.143
    capacity           6.124

The result is essentially flat across occupancy.

There is no near-capacity performance cliff.

P08e carries a small, approximately 4 % owner-only overhead relative to the
single-steal control in this workload, but that overhead is stable rather than
occupancy-dependent.

### DMD correctness

Both implementations also completed the complete occupancy matrix and
capacity-transition checks successfully under DMD.

P08e remained in approximately the same owner-performance class as the
single-steal control.

## P09b — Concurrent near-capacity refill

P09b starts the queue completely full.

A thief removes exactly:

    4,000,000 items

while the owner concurrently pushes exactly the same number of new items.

The intended steady-state pressure is:

    full queue
        ↓
    thief frees one or more slots
        ↓
    owner reuses those slots
        ↓
    queue approaches full again

At completion the queue must be exactly full again.

The complete submitted value set is then verified by draining the remaining
queue and combining it with the stolen set.

Validation uses both:

    arithmetic sum
    XOR checksum

to strengthen duplicate/loss detection.

Configuration:

    capacity   = 65,536
    transfers  = 4,000,000
    batch size = 8
    warmups    = 4
    samples    = 15
    owner CPU  = 2
    thief CPU  = 3

## LDC results

Single-steal:

    median             = 35.411 ns/transfer
    p10 / p90          = 29.918 / 35.903 ns
    stolen             = 60,000,000
    claims             = 60,000,000
    stolen / claim     = 1.000
    failed pushes      = 179,031,069
    thief retries      = 0

P08e:

    median             = 6.772 ns/transfer
    p10 / p90          = 6.523 / 6.815 ns
    stolen             = 60,000,000
    claims             = 7,500,000
    stolen / claim     = 8.000
    failed pushes      = 22,551,263
    thief retries      = 0
    owner busy retries = 0

Equivalent scheduler-mechanism speedup:

    35.411 / 6.772 ≈ 5.23x

P08e therefore retains full batch utilization under this LDC near-capacity
producer/thief workload.

The result is not a language-level D-versus-C++ claim. It compares two D queue
mechanisms under identical work.

## DMD results

Single-steal:

    median             = 76.405 ns/transfer
    stolen / claim     = 1.000
    failed pushes      = 27,289,607

P08e:

    median             = 67.067 ns/transfer
    stolen / claim     = 1.267
    failed pushes      = 107,749
    thief retries      = 1,319,291
    owner busy retries = 0

Correctness remained exact.

The lower DMD batch occupancy is recorded as an observed runtime/compiler
interaction in this producer/refill workload.

It does not currently indicate a queue correctness failure:

- all submitted values are accounted for;
- final capacity is exact;
- no busy marker leaks;
- no owner busy retries occur;
- P08e remains faster than the single-steal control.

LDC remains the designated primary optimized-performance compiler.

The DMD behaviour should be revisited when realistic scheduler workloads are
introduced rather than optimized in isolation here.

## Correctness result

Across both P09a and P09b:

- push beyond capacity is rejected;
- recovery after freeing capacity succeeds;
- live slots are not overwritten;
- occupancy remains within the bounded contract;
- near-capacity slot reuse succeeds;
- exact item accounting is preserved;
- final full-state recovery succeeds;
- verification drain contains exactly the remaining items;
- no P08e batch marker leaks;
- no observed P08e owner-busy anomaly appears in P09b.

## Performance result

P09a demonstrates that ordinary owner cost is not sensitive to occupancy.

P09b demonstrates that the selected P08e architecture remains performant under
continuous near-capacity slot reuse.

There is no evidence of a structural near-capacity performance cliff.

## P09 decision

    PASS

The P09 exit criteria from `PRODUCTION_QUALIFICATION_PLAN.md` are satisfied:

- bounded occupancy is correct;
- near-capacity behaviour is correct;
- full detection does not overwrite live work;
- recovery from full is correct;
- batch stealing and slot reuse coexist correctly;
- no unexplained material LDC performance cliff is observed.

## Next gate

Proceed to:

    P10 — Element and lifetime contract

Do not begin scheduler overflow policy or public Executor/Task API work as part
of P10.

P10 must first establish what the deque may safely store and transfer.
