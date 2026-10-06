# R0.1 P08 — RMW Barrier and Queue Layout Qualification

## Status

Qualified research result.

The current preferred R0.1 bounded work-stealing deque candidate combines:

- modular `ulong` counters;
- the qualified LDC/x86_64 sequentially-consistent RMW barrier lowering;
- portable/DMD sequentially-consistent fence fallback;
- cache-line separation of the contended `top` and `bottom` indices.

This is a research conclusion, not yet a public API or production contract.

## Toolchain

D:

- LDC 1.41.0
- DMD frontend 2.111.0
- LLVM 19.1.7
- `-mcpu=skylake`

Correctness control:

- DMD 2.111.0

C++ reference:

- GCC 15.2.0
- `-O3 -DNDEBUG -march=skylake`
- C++20

Machine:

- Intel Core i7-9750H
- 6 physical cores / 12 hardware threads
- x86_64 Linux

## Taskflow reference

Taskflow commit:

`bbd7251d577b33a4aeff434ce5f5569b94d4cc48`

Relevant source:

`taskflow/core/wsq.hpp`

Reference type:

`tf::BoundedWSQ<std::size_t, LogSize>`

Relevant Taskflow layout observed for the benchmarked specialization:

- `top` at `+0x00`
- `bottom` at `+0x40`
- buffer at `+0x80`

## Correctness qualification

### Modular counter qualification

The modular candidate passed:

- ordinary sequential behaviour;
- physical `ulong` wraparound;
- last-item race across wrap;
- multi-thief accounting across wrap.

### RMW barrier candidate

P02c last-item wrap race:

- 1,000,000 iterations;
- DMD PASS;
- LDC PASS;
- DMD `-preview=nosharedaccess` PASS;
- LDC `-preview=nosharedaccess` PASS;
- zero violations;
- zero non-canonical empty states.

P03c multi-thief wrap:

- 2,000 rounds;
- 8 thieves;
- 512,000 submitted values;
- DMD PASS;
- LDC PASS;
- DMD `-preview=nosharedaccess` PASS;
- LDC `-preview=nosharedaccess` PASS;
- zero missing values;
- zero duplicates;
- zero out-of-range values;
- zero push failures;
- zero invalid empty states.

## Barrier code generation

The original LDC sequentially-consistent fence lowers to:

    mfence

For the qualified research candidate on LDC/x86_64, an idempotent
sequentially-consistent RMW lowers through LLVM to a locked barrier form:

    lock or DWORD PTR [rsp-0x40], 0

The helper is fully inlined in optimized LDC builds.

DMD uses the portable sequentially-consistent fence fallback.

This is a narrowly qualified Chase-Lev ordering mechanism. It must not be
described as a general replacement for `atomicFence(seq)`.

## P06 benchmark-harness correction

An audit found that early P06/P06c preparation code performed `tryPush`
inside `assert(...)`.

Release builds removed those calls together with the assertions.

Consequences:

- early `pop-many` release measurements actually measured empty pop;
- early `successful-steal` measurements actually measured empty steal;
- early `push-pop-pair` measurements started from the wrong occupancy.

Those measurements are invalid and must not be used as performance evidence.

The corrected harness performs all state-changing preparation outside
assertions and uses release-safe failure paths.

For corrected P06c with:

- capacity 262,144;
- 6 warmups;
- 24 samples;
- two D variants;

the aggregate checksum is exactly:

`6184886599560`

## Corrected single-thread RMW result

Representative corrected LDC/Skylake medians:

| Workload | Modular fence baseline | Modular RMW |
| --- | ---: | ---: |
| push | ~1.5 ns/op | ~1.4–1.5 ns/op |
| pop-many | ~16.65 ns/op | ~5.99 ns/op |
| push-pop-pair | ~17.99 ns/op | ~5.84 ns/op |
| empty-steal | ~16–17 ns/op | ~5.8–6.0 ns/op |
| successful-steal | ~23–26 ns/op | ~11.9–12.5 ns/op |

The RMW mechanism removes the dominant `mfence` cost from the qualified LDC
hot paths.

## P08 layout control

Two RMW variants were compared.

### Compact

Approximate relevant layout:

- `top` near `+0x00`
- `bottom` near `+0x08`
- buffer near `+0x18`

### Padded

Taskflow-parity layout:

- `top` at `+0x00`
- `bottom` at `+0x40`
- buffer at `+0x80`

The research-only RMW operand occupies otherwise-unused padding.

### Fixed-affinity cross-core result

Owner CPU 2, thief CPU 3.

These are distinct physical cores.

| Run | Compact | Padded | Padded / Compact |
| --- | ---: | ---: | ---: |
| 1 | 32.391 ns/item | 31.199 ns/item | 0.963x |
| 2 | 32.998 ns/item | 30.488 ns/item | 0.924x |

Cache-line separation improves the real owner/thief workload by roughly
4–8 percent in these fixed-affinity runs.

The padded variant had zero steal retries in both runs.

### SMT control

Owner CPU 2, thief CPU 8.

These are SMT siblings on physical core 2.

| Run | Compact | Padded | Padded / Compact |
| --- | ---: | ---: | ---: |
| 1 | 19.173 ns/item | 19.506 ns/item | 1.017x |
| 2 | 19.113 ns/item | 19.565 ns/item | 1.024x |

The padding advantage disappears on SMT siblings and becomes a small cost.

This topology-dependent reversal supports false sharing, rather than a generic
layout artifact, as the cause of the cross-core result.

## Taskflow streaming parity

Workload:

- one owner;
- one thief;
- bounded capacity 4,096;
- 4,000,000 items per sample;
- 4 warmups;
- 15 measured samples;
- exact per-thread CPU affinity;
- identical arithmetic checksum requirement.

Aggregate checksum for every variant:

`120000030000000`

### Cross-core: CPU 2 -> CPU 3

| Run | D padded RMW | Taskflow | D / Taskflow |
| --- | ---: | ---: | ---: |
| 1 | 31.199 ns/item | 42.562 ns/item | 0.733x |
| 2 | 30.488 ns/item | 44.613 ns/item | 0.683x |

The D candidate uses approximately 27–32 percent fewer nanoseconds per item.

### SMT: CPU 2 -> CPU 8

| Run | D padded RMW | Taskflow | D / Taskflow |
| --- | ---: | ---: | ---: |
| 1 | 19.506 ns/item | 32.618 ns/item | 0.598x |
| 2 | 19.565 ns/item | 32.661 ns/item | 0.599x |

The D candidate uses approximately 40 percent fewer nanoseconds per item.

## Interpretation

The qualified result supports all of the following:

1. Modular counter semantics do not prevent high-performance code.
2. LDC's `mfence` lowering was a major hot-path cost in the original D
   baseline.
3. The qualified RMW barrier form substantially reduces that cost.
4. Cache-line separation matters under real cross-core owner/thief traffic.
5. The effect disappears on SMT siblings, supporting a false-sharing
   explanation.
6. In the tested semantically matched streaming workload, the padded D RMW
   candidate reaches and exceeds the concrete Taskflow C++ reference.

The result does **not** establish that D is generally faster than C++ or that
the current research candidate is ready for public production use.

## Remaining qualification

Before R0.1 promotion:

- one owner plus multiple thieves;
- repeated contention at different occupancies;
- TaskRef width control;
- batch-steal experiments;
- representative scheduler/end-to-end workloads;
- weak-memory / non-x86 strategy;
- final safety boundary;
- production ownership decision with `containers-d`.
