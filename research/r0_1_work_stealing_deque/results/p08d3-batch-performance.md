# R0.1 P08d3 — Batch-Steal Performance Qualification

## Status

Qualified research result.

The owner-coordinated gate design from P08d2 is rejected as a general
production work-stealing deque architecture.

The result does not reject batch stealing itself.

Instead, it shows that batch stealing can provide a large reduction in
thief-side claim traffic, but that serializing owner `pop()` and batch claims
through one shared gate creates unacceptable mixed-workload contention.

## Background

P08c established that multiple steal-one thieves scale poorly because they
contend on the shared `top` compare-and-swap.

P08d then established:

- P08d0: naive `CAS(top, top + N)` is incorrect;
- P08d1: repeated qualified `steal()` is a correct batch semantic reference;
- P08d2: one-CAS multi-item reservation can be made correct by coordinating
  owner `pop()` and batch claims through an additional gate.

P08d3 measures the performance consequences.

## Toolchain and machine

Primary performance compiler:

- LDC 1.41.0
- DMD frontend 2.111.0
- LLVM 19.1.7
- `-mcpu=skylake`

Correctness/build control:

- DMD 2.111.0

Machine:

- Intel Core i7-9750H
- 6 physical cores / 12 hardware threads
- x86_64 Linux

## P08d3a — Thief-side batch streaming

### Workload

- one owner pushes;
- four fixed-affinity thieves consume;
- owner does not pop;
- 4,000,000 items per sample;
- capacity 4,096;
- 4 warmups;
- 15 samples;
- checksum gate retained.

Compared mechanisms:

1. current padded RMW `steal-one`;
2. P08d1 repeated-steal semantic reference;
3. P08d2 coordinated single-CAS batch.

Batch sizes:

    1, 2, 4, 8, 16, 32

### Correctness

Every variant produced the aggregate checksum:

`120000030000000`

No accounting failure occurred.

### Steal-one baseline

Run 1:

    128.319 ns/item

Run 2:

    137.776 ns/item

Each transferred item requires one successful claim:

    items/claim = 1.000
    claims/item = 1.00000

### Repeated-steal reference

Representative medians:

| Batch | Run 1 | Run 2 |
| ---: | ---: | ---: |
| 1 | 128.053 | 152.517 |
| 2 | 124.223 | 175.063 |
| 4 | 126.737 | 125.494 |
| 8 | 123.353 | 164.376 |
| 16 | 127.955 | 126.010 |
| 32 | 172.462 | 141.677 |

Units are ns/item.

Despite larger caller-visible batches, the effective number of items obtained
per successful batch call rises only to approximately 2.2–2.3.

The underlying implementation still performs one qualified `steal()` and one
`top` claim per transferred item.

Therefore repeated-steal batching does not materially remove the P08c
contention mechanism.

### Coordinated single-CAS batch

| Batch | Run 1 | Run 2 | Items / claim |
| ---: | ---: | ---: | ---: |
| 1 | 261.304 | 294.887 | 1.000 |
| 2 | 133.205 | 160.635 | 2.000 |
| 4 | 67.081 | 73.427 | 4.000 |
| 8 | 34.078 | 51.041 | ~7.99 |
| 16 | 62.199 | 66.645 | ~6.1 |
| 32 | 81.670 | 78.771 | ~6.2 |

Units are ns/item.

### Interpretation

The result demonstrates real CAS amortization.

Batch 8 is the clear local optimum in this workload.

Compared with steal-one, batch 8 is approximately:

- 3.8x faster in run 1;
- 2.7x faster in run 2.

The claim rate falls from:

    1 claim / item

to approximately:

    0.125 claims / item

for batch 8.

Batch 16 and 32 do not achieve their nominal batch width because the bounded
streaming queue frequently contains fewer immediately available items.

Batch 1 is substantially slower than steal-one because it pays the additional
gate synchronization without any claim amortization.

This proves that batch stealing itself is promising, but does not prove that
the P08d2 gate architecture is suitable.

## P08d3b — Uncontended owner gate cost

### Goal

Measure the owner-side price of the P08d2 coordination gate without thief
contention.

Controls:

- padded RMW baseline;
- P08d1 safe-reference queue;
- P08d2 gated queue.

The baseline and safe-reference results match closely, validating the control.

### Pop-many

Run 1:

    baseline    6.147 ns/op
    safe-ref    6.155 ns/op
    gated      11.040 ns/op

Run 2:

    baseline    6.005 ns/op
    safe-ref    6.002 ns/op
    gated      11.027 ns/op

The uncontended gate increases owner pop cost by approximately 80–84 percent.

### Push-pop pair

Run 1:

    baseline   13.982 ns/op
    safe-ref   13.853 ns/op
    gated      19.619 ns/op

Run 2:

    baseline   14.032 ns/op
    safe-ref   13.878 ns/op
    gated      19.506 ns/op

The uncontended gate increases the pair workload by approximately 39–40
percent.

### Interpretation

The gate is not free even when uncontended.

However, these isolated costs alone are not sufficient to reject it because
P08d3a showed a much larger thief-side batch benefit.

A concurrent owner/thief workload is therefore required.

## P08d3c — Concurrent owner/thief drain

### Workload

- queue prefilled with 1,048,576 items;
- owner CPU 2 concurrently pops from bottom;
- four thieves concurrently steal from top;
- batch size 8;
- 4 warmups;
- 15 measured samples;
- no producer during timed drain.

Aggregate checksum for every variant:

`8246345072640`

All variants passed accounting.

### Steal-one

Run 1:

    60.555 ns/item

Run 2:

    61.349 ns/item

Work distribution across 15 samples:

Run 1:

    owner  = 7,974,932
    stolen = 7,753,708

Run 2:

    owner  = 7,972,241
    stolen = 7,756,399

### Repeated-steal batch

Run 1:

    61.306 ns/item
    stolen/claim = 2.224

Run 2:

    61.324 ns/item
    stolen/claim = 2.200

The repeated-steal semantic batching provides effectively no total throughput
advantage over steal-one in this workload.

### Coordinated single-CAS batch

Run 1:

    median = 299.341 ns/item
    p10/p90 = 52.160 / 455.977 ns/item
    stolen/claim = 8.000

Run 2:

    median = 318.279 ns/item
    p10/p90 = 237.799 / 516.815 ns/item
    stolen/claim = 8.000

Compared with steal-one, the median is approximately:

- 4.9x slower in run 1;
- 5.2x slower in run 2.

The batch mechanism itself works exactly as intended:

    stolen/claim = 8.000

The throughput collapse therefore does not come from failure to form batches.

### Hidden gate contention

The reported thief retry count is only:

    60

across the 15-sample aggregate.

This must not be interpreted as low contention.

The metric counts failed queue operations after `stealBatch()` returns.

It does not count spinning inside `_batchClaimGate`.

The large latency increase and extreme p10/p90 spread demonstrate that the
dominant contention has moved from the visible `top` CAS retry loop into the
coordination gate.

## Final P08d3 conclusion

Batch stealing remains a promising mechanism.

The following are now established:

1. steal-one exhibits severe multi-thief `top` contention;
2. caller-visible batching implemented as repeated single steals does not
   remove that contention;
3. one successful multi-item claim can reduce claim frequency by almost the
   batch width;
4. batch size 8 is a strong local optimum for the tested streaming workload;
5. forcing owner `pop()` and batch claims through a single gate causes severe
   mixed-workload contention;
6. the P08d2 gate candidate is therefore rejected as a general WSQ design.

The key architectural requirement for the next candidate is:

> allow a thief to claim multiple tasks atomically without serializing ordinary
> owner bottom operations through the same contended gate.

## Next research direction

Do not optimize `_batchClaimGate`.

Instead investigate state representations that couple enough information for
safe batch reservation without placing a shared lock/spin gate on the owner
hot path.

Candidate directions include:

- packed claim state carrying additional validation information;
- versioned or epoch-tagged claim state;
- two-phase batch reservation with independently detectable owner movement;
- architecture/compiler-qualified wider atomic state only if portability and
  fallback semantics remain acceptable.

Any new candidate must first reproduce the P08d0 overlap scenario as a
correctness gate before performance measurement.

The existing P08d1 repeated-steal implementation remains the semantic oracle.
