# P14 — End-to-End Scheduler Qualification

Status: PASS

## Goal

Qualify the selected P08e marked-top bounded work-stealing deque in
end-to-end scheduler workloads rather than isolated queue microbenchmarks.

The qualification covers:

- flat fine, medium, and coarse tasks;
- recursive fork/join task production;
- deterministic irregular task production;
- single-steal D controls;
- P08e batch-steal D controls;
- pinned Taskflow `BoundedWSQ` controls where semantically feasible.

The benchmark discipline follows `BENCHMARK_PLAN.md` and
`PRODUCTION_QUALIFICATION_PLAN.md`.

Performance comparisons are scheduler/workload comparisons. They are not
claims that D is inherently faster or slower than C++.

## Environment

Primary optimized compiler:

- LDC 1.41.0
- D frontend 2.111.0
- LLVM 19.1.7

Correctness/code-generation comparison:

- DMD 2.111.0

C++ reference:

- GCC 15.2.0
- Taskflow commit:
  `bbd7251d577b33a4aeff434ce5f5569b94d4cc48`

Machine:

- x86_64 Linux
- Intel Core i7-9750H
- 6 physical cores / 12 logical CPUs

Worker benchmarks pin workers to physical CPUs starting at CPU 0.

## Queue configuration

D candidate:

- `MarkedTopBatchBoundedWorkStealingDeque`
- P08e selected candidate
- capacity: 1024
- batch size: 8
- bounded local queues
- P12 execute-inline overflow policy

Taskflow control:

- `tf::BoundedWSQ<T, 10>`
- capacity: 1024
- single-item steal
- identical owner-local bounded-queue policy where applicable

## P14a — Flat fine / medium / coarse scaling

Workload:

- 262144 deterministic tasks
- one producer
- 1, 2, and 4 workers
- work rounds:
  - 0
  - 16
  - 64
- 2 warmups
- 9 measured samples

### LDC results

| Work | Workers | D single | D P08e batch |
|---:|---:|---:|---:|
| 0 | 1 | 7.036 ns/task | 7.410 ns/task |
| 0 | 2 | 7.607 | 9.591 |
| 0 | 4 | 10.406 | 24.736 |
| 16 | 1 | 34.114 | 34.568 |
| 16 | 2 | 33.449 | 32.092 |
| 16 | 4 | 37.091 | 30.297 |
| 64 | 1 | 152.464 | 153.643 |
| 64 | 2 | 138.662 | 101.230 |
| 64 | 4 | 115.963 | 58.100 |

### Interpretation

Batch stealing is not universally faster.

For extremely small flat tasks, batch coordination costs dominate. At
`work=0`, four-worker P08e is substantially slower than single-steal.

As useful work and steal pressure increase, batch transfer amortizes strongly.

At `work=64`, four workers:

- D single: 115.963 ns/task
- D P08e batch: 58.100 ns/task

The P08e batch path therefore needs about half the time of the D single-steal
control in this workload.

Batch utilization remains substantial under real contention rather than only
isolated queue tests.

## P14d — Taskflow flat control

The Taskflow control mirrors the P14a single-steal scheduler harness:

- same task count;
- same work function;
- same worker counts;
- same bounded capacity;
- same execute-inline overflow policy;
- production remains inside the measured interval.

### Taskflow results

| Work | Workers | Taskflow |
|---:|---:|---:|
| 0 | 1 | 7.050 ns/task |
| 0 | 2 | 8.861 |
| 0 | 4 | 19.470 |
| 16 | 1 | 29.106 |
| 16 | 2 | 33.139 |
| 16 | 4 | 41.571 |
| 64 | 1 | 145.012 |
| 64 | 2 | 130.430 |
| 64 | 4 | 113.618 |

### Flat control conclusion

D single-steal and Taskflow `BoundedWSQ` are in the same performance class.

Examples:

- `work=0`, 1 worker:
  - D single: 7.036
  - Taskflow: 7.050 ns/task
- `work=16`, 2 workers:
  - D single: 33.449
  - Taskflow: 33.139
- `work=64`, 4 workers:
  - D single: 115.963
  - Taskflow: 113.618

The large P08e advantage in the steal-heavy coarse flat workload therefore
comes from scheduler/steal architecture rather than from comparing against an
obviously weak C++ baseline.

This must not be interpreted as a general D-versus-C++ language comparison.

## P14b — Recursive fork/join baseline

Workload:

- deterministic complete binary tree
- depth 18
- 524287 tasks
- work rounds: 16
- dynamic child production by executing tasks
- owner-local LIFO
- stealing under imbalance
- 1, 2, and 4 workers

All runs satisfy:

- exact execution count;
- exact spawn count;
- exact sum;
- exact xor;
- exact work checksum;
- `outstanding == 0`;
- all queues empty after completion.

### Original LDC baseline

| Workers | D single | D batch |
|---:|---:|---:|
| 1 | 94.318 ns/task | 98.108 ns/task |
| 2 | 57.430 | 55.575 |
| 4 | 59.475 | 56.261 |

The workload is strongly owner-local:

- `localRatio = 1.000`
- very few successful steals relative to total task count
- no queue overflow

## P14e — Taskflow recursive control

Taskflow mirrors the same binary tree, work function, capacity, worker counts,
checksums, and termination accounting.

| Workers | Taskflow |
|---:|---:|
| 1 | 41.997 ns/task |
| 2 | 46.042 |
| 4 | 48.816 |

The unexpectedly large one-worker gap against the original D P14b result
required investigation before accepting the comparison.

## P14f — Recursive hot-path diagnostic

The D diagnostic removed recursion from the normal `executeTask` path by
turning the never-observed overflow case into a diagnostic failure.

No measured P14b run had overflow.

### LDC diagnostic

| Workers | D single | D batch |
|---:|---:|---:|
| 1 | 40.211 ns/task | 39.410 ns/task |
| 2 | 55.006 | 54.933 |
| 4 | 55.105 | 54.788 |

The one-worker single-steal result changed from:

- 94.318 ns/task

to:

- 40.211 ns/task

This isolated the large gap to the recursive form of the D hot path rather
than to the deque algorithm.

DMD showed the same qualitative effect:

- original: 200.857 ns/task
- diagnostic: 98.017 ns/task

## P14g — Semantically complete recursive cold-overflow split

P14g restores complete P12 overflow semantics while keeping recursion out of
the normal task-execution hot path.

The normal path is non-recursive.

The rare overflow path uses a separate recursive execute-inline helper.

### LDC results

| Workers | D single | D batch |
|---:|---:|---:|
| 1 | 39.881 ns/task | 41.301 ns/task |
| 2 | 43.347 | 42.554 |
| 4 | 37.169 | 36.913 |

### Comparison with Taskflow

| Workers | D single | D batch | Taskflow |
|---:|---:|---:|---:|
| 1 | 39.881 | 41.301 | 41.997 |
| 2 | 43.347 | 42.554 | 46.042 |
| 4 | 37.169 | 36.913 | 48.816 |

The semantic cold-overflow split removes the code-generation gap while
retaining the selected overflow behavior.

This is production-relevant evidence:

- hot scheduler paths should be shaped for compiler optimization;
- cold semantic paths should not unnecessarily constrain hot-path codegen;
- however, such transformations must still be measured workload by workload.

## P14c — Irregular deterministic workload

Workload:

- four workers
- depth 18
- 218643 deterministic tasks
- 218642 spawned descendants
- deterministic fanout:
  - 0
  - 1
  - 2
  - 4 children
- deterministic heterogeneous work:
  - 0
  - 8
  - 24
  - 64 rounds
- changing victim pressure
- intermittent idle periods
- repeated idle-to-work transitions

### LDC results

- D single: 53.765 ns/task
- D P08e batch: 52.770 ns/task

Diagnostics include:

- successful steals;
- idle transitions;
- non-zero marked-top busy retries in the batch path;
- no overflow;
- execution distributed across all workers.

The batch advantage is small in this strongly owner-local workload.

## P14h — Irregular cold-overflow experiment

The recursive cold-overflow split from P14g was applied to the irregular
workload.

### LDC results

- single: 61.108 ns/task
- batch: 64.695 ns/task

The result is worse than original P14c and considerably noisier.

Therefore the recursive P14b finding must not be generalized mechanically.

The evidence supports a narrower production rule:

> Hot/cold code restructuring must be justified by compiler and workload
> evidence. A transformation that benefits one scheduler hot path may regress
> another.

P14c remains the selected irregular D reference.

## P14i — Taskflow irregular control

Taskflow mirrors:

- the exact deterministic graph;
- identical `mix`;
- identical fanout rules;
- identical work-round selection;
- identical depth;
- identical capacity;
- identical checksum and termination accounting.

Result:

- Taskflow: 50.034 ns/task

Comparison:

| Variant | ns/task |
|---|---:|
| Taskflow single-steal | 50.034 |
| D P08e batch | 52.770 |
| D single-steal | 53.765 |

The remaining difference is modest:

- Taskflow is about 5.2% faster than D batch;
- Taskflow is about 7.5% faster than D single.

This does not indicate the structural code-generation problem found in the
original recursive P14b form.

## Cross-workload summary

Representative four-worker LDC/GCC results:

| Workload | D single | D P08e batch | Taskflow |
|---|---:|---:|---:|
| Flat work=0 | 10.406 | 24.736 | 19.470 |
| Flat work=16 | 37.091 | 30.297 | 41.571 |
| Flat work=64 | 115.963 | 58.100 | 113.618 |
| Recursive, qualified hot path | 37.169 | 36.913 | 48.816 |
| Irregular | 53.765 | 52.770 | 50.034 |

## Conclusions

### 1. Fundamental single-steal performance is competitive

The D single-steal scheduler is generally in the same performance class as the
pinned Taskflow `BoundedWSQ` control.

The flat workload gives particularly direct evidence because both controls move
one task per successful steal.

### 2. P08e batch stealing is workload dependent

P08e is not a universal performance win.

It loses for extremely small tasks where coordination costs dominate.

It gains as steal cost can be amortized across useful work.

The strongest P14 result is the steal-heavy flat coarse workload:

- D single: 115.963 ns/task
- Taskflow: 113.618 ns/task
- P08e batch: 58.100 ns/task

The gain is architectural and must not be described as language superiority.

### 3. Work-first locality remains important

Recursive and irregular task graphs are predominantly owner-local.

In these workloads:

- local LIFO execution dominates;
- only limited stealing is required;
- batching has less room to improve total time.

### 4. Compiler-aware hot-path structure matters

P14b exposed a major D code-generation sensitivity.

A recursive cold path attached directly to the normal task execution function
caused a large LDC and DMD regression despite never being taken in the measured
workload.

A separate cold overflow helper restored competitive LDC performance without
weakening semantics.

The P14h counterexample shows that this is not a universal mechanical
transformation rule.

### 5. Correctness remained intact

Across all selected P14 workloads:

- exact execution accounting passes;
- exact spawn accounting passes where applicable;
- sum/xor/work checksums pass;
- termination accounting passes;
- queues drain completely;
- bounded overflow semantics remain explicit;
- marked-top owner/batch overlap is exercised in scheduler-level workloads.

## Exit criteria

P14 requires the selected P08e deque to remain correct and competitive from
fine through coarse scheduler workloads without severe scheduler-policy
regression.

Result: PASS.

Evidence shows:

- correctness across all required synthetic workload families;
- competitiveness against the D single-steal control;
- competitiveness against the pinned Taskflow bounded-WSQ control;
- strong batch benefit where transfer amortization is available;
- explicitly identified workloads where batching is not beneficial;
- a resolved compiler/hot-path issue rather than hiding the original
  regression.

## Production guidance carried forward

For later scheduler implementation:

1. retain bounded owner-local queues;
2. retain P12 execute-inline overflow as the current ordinary-runnable-task
   direction;
3. retain P08e marked-top batch capability;
4. do not assume batch stealing should be used unconditionally;
5. leave room for workload-sensitive steal policy;
6. keep normal scheduler hot paths compiler-friendly;
7. isolate rare semantic paths only when measurement justifies it;
8. preserve exact accounting and deterministic workload validation in future
   scheduler qualification.

## Next gate

P15 — additional architecture / native AArch64 qualification.
