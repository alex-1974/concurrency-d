# R0.1 Benchmark Plan

## Primary performance compiler

LDC 1.41.0 / LLVM 19.1.7

DMD 2.111.0 is retained as a correctness and code-generation comparison.

## Reference implementations

At minimum:

- Taskflow bounded WSQ in C++;
- D bounded baseline.

Later:

- cached-top D variant;
- batch-steal D variant;
- Crossbeam/Rayon-style control where a fair isolated comparison is possible.

## Microbenchmarks

### Owner-local

1. push only
2. pop only
3. push + pop pair
4. steady-state bounded occupancy
5. near-capacity operation

### Stealing

1. empty steal
2. successful single steal
3. one owner + one thief
4. one owner + N thieves
5. last-item race
6. repeated steal contention

### Batch

1. steal-one
2. steal-half
3. bounded batch

Measure across different queue occupancies.

### End-to-end synthetic

1. recursive fork/join tiny tasks
2. fine tasks
3. medium tasks
4. coarse tasks
5. irregular task production

## Metrics

Primary:

- wall-clock throughput;
- ns/op;
- tasks/s;
- scaling.

Diagnostic:

- retired instructions;
- cycles;
- cache references/misses;
- branch misses;
- context switches;
- allocations.

## Measurement discipline

Record:

- exact commit;
- compiler version;
- flags;
- CPU;
- affinity;
- warm-up;
- sample count;
- median and distribution;
- workload size;
- reference commit/tag.

Performance comparisons must perform materially equivalent work.
