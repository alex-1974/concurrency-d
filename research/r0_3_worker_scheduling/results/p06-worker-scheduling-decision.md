# R0.3 P06 — Worker-scheduling decision

Status: PASS

## Decision

R0.3 selects the following internal worker-scheduling contract for R0.4 and
later R1 scheduler construction.

```text
victim selection:
    deterministic round-robin

searching workers before parking exists:
    all idle workers may search

continuation policy:
    AArch64:
        saturation-gated direct-one
        direct continuation only when
        scheduler-visible outstanding work >= worker count

    x86_64 and other currently qualified targets:
        enqueue-all

steal width:
    single and batch remain explicit scheduler choices
    no universal dynamic selector selected in R0.3

overflow:
    retain P12 execute-inline fallback

completion:
    scheduler-owned exact outstanding/completed accounting
```

Architecture specialization is compile-time.

There is no runtime architecture test in the worker hot path.

## Why round-robin

P02 compared:

- deterministic round-robin;
- deterministic per-worker random;
- sticky-success.

Sticky-success reduced victim switching strongly but was not
architecture-robust and caused severe flat-workload regressions on AArch64.

Random did not provide a consistent cross-workload advantage.

Round-robin remained the simplest robust baseline across all qualified
workloads and architectures.

## Why all idle workers may search

P03 compared:

- all idle workers searching;
- one active searcher;
- a bounded searcher count.

Searcher limits reduced failed-steal traffic but often slowed work discovery.

Without an actual park/wake primitive, denied searchers only spin/yield, so
the reduction in steal traffic did not translate to a robust throughput gain.

Therefore R0.3 retains all-idle searching.

This is explicitly a pre-parking decision.

R0.4 must revisit searcher limits together with a real parking/wake mechanism.

## Why continuation is architecture-specialized

Direct continuation showed a real architecture split.

### AArch64

Native Neoverse-N2 consistently benefits from keeping one continuation local
after enough work has been exposed.

Final matched P05 ratios against enqueue-all:

```text
recursive:
    approximately 0.76x .. 0.88x

irregular:
    approximately 0.79x
```

This is a large, repeatable improvement.

### x86_64

Generic direct continuation and generic saturation/headroom thresholds were not
stable enough to select.

The final x86 policy is therefore the unchanged enqueue-all implementation.

The qualification deliberately runs that selected implementation directly,
rather than comparing a separately compiled duplicate candidate whose module
and function layout can perturb optimized code generation.

## Benchmark-methodology finding

R0.3 produced an important negative result about scheduler benchmarking.

A semantically identical duplicate executable is not necessarily a fair
performance proxy for the selected implementation.

The first XPS P05 attempt reported:

```text
irregular single 1.0644x
irregular batch  1.1252x
candidate spread 1.2576x
```

even though x86 continuation was compile-time disabled.

A later duplicate-binary hosted run also reached:

```text
recursive single / 4 workers = 1.1012x
```

This is consistent with earlier project evidence that compiler function shape,
module layout and codegen can materially affect scheduler microbenchmarks.

Therefore future performance gates should compare actual selected
implementations, not merely semantically equivalent duplicate harness binaries.

## Local XPS qualification

Platform:

```text
Intel Core i7-9750H
6 cores / 12 threads
Linux x86_64
LDC 1.41.0
DMD frontend 2.111.0
LLVM 19.1.7
host CPU skylake
```

Corrected P05 selected-x86 qualification:

```text
R0.3 P05 XPS SELECTED-X86 QUALIFICATION: PASS
overall_rc=0
```

Selected recursive medians across three complete runs:

```text
batch  1w 65.293 ns/task
single 1w 62.837

batch  2w 55.071
single 2w 55.431

batch  4w 55.746
single 4w 56.607
```

Selected irregular medians:

```text
single 51.868 ns/task
batch  51.899 ns/task
```

The repeated-run spread is retained as a measurement-environment caveat rather
than hidden.

## Correctness and architecture coverage

R0.3 qualified:

- flat fine/medium/coarse work;
- recursive fork/join;
- irregular graph;
- single steal;
- batch steal;
- bounded local queues;
- execute-inline overflow behavior;
- exact task/spawn/sum/xor/work checksums.

Compilers/platforms:

- DMD 2.111 / x86_64;
- LDC 1.41 / hosted x86_64;
- LDC 1.41 / local native XPS x86_64;
- LDC 1.41 / native AArch64 / Neoverse-N2.

## Deferred decisions

Explicitly deferred:

- parking primitive -> R0.4;
- wake-one / wake-many policy -> R0.4;
- spin/yield/park transition -> R0.4;
- allocator/pool topology -> R0.5;
- public Scheduler API -> R1;
- WorkerPool API -> R1;
- TaskScope -> R1;
- cancellation -> R1;
- typed results -> R1.

## R0.3 exit criteria

- explicit victim-selection rule: PASS;
- explicit searching-worker rule: PASS;
- explicit continuation/direct-execution rule: PASS;
- scheduler-neighborhood correctness: PASS;
- flat/recursive/irregular evidence: PASS;
- DMD/LDC qualification: PASS;
- local XPS qualification: PASS;
- native AArch64 qualification: PASS;
- parking/allocation/public API clearly deferred: PASS.

Result:

```text
R0.3 WORKER SCHEDULING: PASS
```

## Next research gate

R0.4 — Parking/wake.

R0.4 should begin from the selected R0.3 scheduling contract and determine:

- spin/yield/park transition;
- platform wait abstraction;
- wake-one versus wake-many;
- interaction between active-searcher limits and parking;
- lost-wakeup correctness;
- shutdown/wakeup behavior;
- latency versus idle CPU cost.

R0.4 must not reopen queue or TaskRef representation without contradictory
evidence.
