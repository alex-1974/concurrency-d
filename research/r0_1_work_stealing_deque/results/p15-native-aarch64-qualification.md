# P15 — Native AArch64 Runtime Qualification

Status: PASS

## Goal

Reduce the asymmetry between the existing x86_64 runtime evidence and the
previously code-generation-only AArch64 evidence.

P15 requires meaningful runtime evidence on at least one additional
architecture. Cross-compilation or assembly inspection alone is not sufficient.

## Native platform

GitHub Actions runner:

- image: `ubuntu-24.04-arm`
- operating system: Ubuntu 24.04.5 LTS
- kernel: Linux 6.17.0-1022-azure
- architecture: `aarch64`
- CPU: ARM Neoverse-N2
- physical/logical CPUs available: 4 / 4
- threads per core: 1

Compiler/runtime:

- LDC 1.41.0
- D frontend 2.111.0
- LLVM 20.1.5
- target: `aarch64-unknown-linux-gnu`
- DUB 1.40.0

The qualification therefore represents native AArch64 execution, not
cross-compilation.

## Evidence run

Final hardened run:

- workflow: `P15 Native ARM64 Qualification`
- run: #8
- run id: `37594056621`
- concurrency-d commit:
  `ad697962500c20346cd9877eacb9a03bf004bb6b`
- conclusion: SUCCESS

The workflow executes all required P15 categories using the selected P08e
candidate or scheduler harnesses that directly embed it.

## Required coverage

### 1. Core correctness

Probe:

- `p08e0_marked_top_batch`

Result:

- PASS
- marked-top batch semantics preserved

This covers basic owner push/pop, thief stealing, batch extraction, wrap
behavior, ordering, and duplicate rejection for the selected candidate.

### 2. Last-item race

Probe:

- `p15_native_aarch64/p15a_selected_last_item`

The probe runs directly against:

- `MarkedTopBatchBoundedWorkStealingDeque!(size_t, 1)`

Result:

- iterations: 100000
- owner wins: 52548
- thief wins: 47452
- violations: 0
- PASS

Exactly one participant wins each last-item race, and the winning value matches
the expected item.

### 3. Multi-thief exact accounting

Probe:

- `p15_native_aarch64/p15b_selected_multi_thief`

The probe runs directly against the selected P08e deque.

Configuration:

- rounds: 256
- capacity: 4096
- thieves: 4
- submitted values: 1048576

Result:

- owner-consumed values: 808939
- thief-consumed values: 239637
- total: 1048576
- exact per-value membership validation: PASS
- duplicate detection: PASS
- missing-value detection: PASS
- queue empty after every round: PASS
- PASS

This is stronger than count/sum-only accounting: every submitted value is
validated exactly once in each round.

### 4. Marked-top batch overlap

Probe:

- `p08e1_marked_top_concurrency`

The probe deterministically forces the critical overlap:

- thief marks top busy;
- owner reaches the busy path;
- batch completion is deliberately delayed;
- owner retries only after batch publication.

Native AArch64 result:

- forced owner result: found
- owner value: 8
- owner busy retries: 6
- stress rounds: 500
- active thieves: 4
- PASS

The selected marked-top protocol therefore survives the forced overlap and
wrap stress on native AArch64.

### 5. Scheduler-like qualification

Probe:

- `p13b_distributed_production`

Workload:

- four workers;
- distributed task production;
- owner-local execution;
- work stealing;
- batch transfer;
- execute-inline overflow policy.

Native AArch64 result:

- produced: 1048576
- executed: 1048576
- exact accounting/checksum: PASS
- ownerBusyRetries: 22
- PASS

The marked-top busy path is exercised under scheduler-like runtime behavior on
AArch64 rather than only in isolated queue tests.

### 6. End-to-end scheduler workload

Probe:

- `p14c_irregular_bursty`

Workload:

- four workers;
- deterministic irregular graph;
- depth 18;
- 218643 tasks;
- heterogeneous task cost;
- changing steal pressure;
- exact accounting and checksums.

Final native AArch64 results:

| Variant | Median | P10 | P90 |
|---|---:|---:|---:|
| D single-steal | 214.759 ns/task | 207.442 | 215.749 |
| P08e batch | 214.895 ns/task | 213.203 | 215.091 |

Additional batch diagnostics:

- non-zero steal claims;
- non-zero marked-top owner busy retries: 54;
- overflow/task: 0;
- exact graph/checksum validation: PASS.

The single and batch forms are effectively equal in this owner-local irregular
workload on the Neoverse-N2 runner.

The absolute times are not compared directly with the x86_64 i7-9750H results,
because the machines are different performance classes.

## Bring-up evidence

The preceding bring-up run also established that:

- the GitHub ARM64 runner reports `aarch64`;
- LDC downloads and executes the native Linux AArch64 distribution;
- the compiler default target is `aarch64-unknown-linux-gnu`;
- the host CPU is detected as `neoverse-n2`;
- P14c builds and runs natively.

This removes the previous architecture-evidence limitation.

## Interpretation

### Correctness

No architecture-specific correctness failure was observed.

The selected P08e protocol passed:

- basic semantics;
- last-item race;
- exact multi-thief accounting;
- forced owner/batch overlap;
- scheduler-like execution;
- end-to-end irregular scheduling.

### Memory-ordering confidence

The native AArch64 evidence is particularly important because AArch64 has a
weaker memory model than x86_64.

The runtime tests do not replace the earlier formal/litmus/code-generation
evidence, but they add direct execution evidence on a weakly ordered
architecture.

### Performance

P15 is not an x86-versus-ARM benchmark.

The native AArch64 performance measurements are used to detect scheduler or
candidate regressions on the additional architecture.

The irregular workload showed no severe batch-policy regression:

- single: 214.759 ns/task
- batch: 214.895 ns/task

Within this workload the two policies are effectively tied.

## Exit criteria

P15 passes when at least one additional architecture has meaningful runtime
evidence, or promotion remains explicitly architecture-limited.

Result: PASS.

Native AArch64 runtime evidence now exists for all required P15 categories.

The selected research candidate is no longer qualified only by x86_64 runtime
evidence plus AArch64 code-generation inspection.

## Production guidance carried forward

1. retain native AArch64 CI coverage for the selected candidate while it
   remains under promotion consideration;
2. preserve exact last-item and multi-thief accounting probes;
3. keep the deterministic forced-overlap gate;
4. keep architecture-specific performance results separated by machine class;
5. do not interpret equal or better numbers on one architecture as a general
   language comparison;
6. combine native runtime evidence with the existing formal, litmus, and
   code-generation evidence rather than replacing those gates.

## Next gate

P16 — ownership and promotion decision.
