# R0.1 P08c — Multi-Thief Streaming Qualification

## Goal

Determine whether the fixed-affinity one-owner/one-thief advantage of the
padded modular RMW candidate scales to multiple concurrent thieves, and compare
the result against the pinned Taskflow bounded work-stealing queue.

## Configuration

D candidate:

- modular `ulong` counters;
- qualified LDC/x86_64 RMW ordering mechanism;
- cache-line separated `top` and `bottom`;
- buffer at the Taskflow-parity offset.

Taskflow reference:

- commit `bbd7251d577b33a4aeff434ce5f5569b94d4cc48`;
- `tf::BoundedWSQ<std::size_t, 12>`.

Common workload:

- capacity: 4,096;
- items per sample: 4,000,000;
- warmups: 4;
- measured samples: 15;
- owner CPU: 2;
- thief CPU order: 3, 4, 1, 5, 0, 9, 10, 7;
- fixed per-thread affinity;
- thief counts: 1, 2, 4, 8.

For 1, 2 and 4 thieves, the active threads occupy distinct physical cores.

The 8-thief case necessarily introduces SMT on the 6-core / 12-thread test
machine.

## Correctness

Both implementations passed for every thief count.

Expected aggregate checksum:

`120000030000000`

Observed checksum for every D and Taskflow 1/2/4/8-thief run:

`120000030000000`

No accounting failure occurred.

## D padded RMW results

| Thieves | Run 1 | Run 2 |
| ---: | ---: | ---: |
| 1 | 28.581 ns/item | 30.071 ns/item |
| 2 | 87.730 ns/item | 86.847 ns/item |
| 4 | 128.848 ns/item | 129.660 ns/item |
| 8 | 161.126 ns/item | 180.462 ns/item |

Aggregate steal retries:

| Thieves | Run 1 | Run 2 |
| ---: | ---: | ---: |
| 1 | 15 | 15 |
| 2 | 44,731,184 | 44,610,615 |
| 4 | 112,339,717 | 112,742,721 |
| 8 | 197,508,830 | 197,666,998 |

## Taskflow results

| Thieves | Run 1 | Run 2 |
| ---: | ---: | ---: |
| 1 | 39.452 ns/item | 44.453 ns/item |
| 2 | 88.448 ns/item | 96.962 ns/item |
| 4 | 131.945 ns/item | 136.335 ns/item |
| 8 | 161.650 ns/item | 257.611 ns/item |

Aggregate steal retries:

| Thieves | Run 1 | Run 2 |
| ---: | ---: | ---: |
| 1 | 15 | 15 |
| 2 | 46,950,381 | 48,198,219 |
| 4 | 111,491,556 | 113,879,383 |
| 8 | 194,341,913 | 197,784,624 |

## Interpretation

The D candidate's strong one-thief result does not turn into positive scaling
when additional thieves compete for the same deque.

The same behaviour is visible in Taskflow.

The most important observation is the similarity of the steal-retry curves.
Both implementations move from effectively zero contention with one thief to
tens or hundreds of millions of failed steal attempts as thief count rises.

This strongly indicates that the dominant scaling limit is the shared
`top` compare-and-swap contention inherent in steal-one operation, rather than
a D-specific implementation problem.

At two and four thieves, the padded D candidate remains approximately at or
ahead of the Taskflow reference.

The eight-thief measurements are substantially noisier because the machine
has only six physical cores and SMT is necessarily introduced. Fine-grained
performance claims from that case are therefore not appropriate.

## Consequence

Cached-top optimization is not the primary next step for this bottleneck.

The next R0.1 mechanism to qualify should reduce thief-side CAS frequency.

The primary candidate is batch stealing:

- steal one;
- steal half;
- bounded batch sizes such as 2, 4, 8, 16 and 32.

The key question is whether one successful CAS can transfer enough work to
amortize contention without damaging fairness or owner locality.

## Status

P08c qualified.

The result supports proceeding to the batch-steal research phase.
