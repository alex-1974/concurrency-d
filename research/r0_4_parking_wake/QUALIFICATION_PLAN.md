# R0.4 — Parking and Wake Qualification Plan

Status: ACTIVE RESEARCH

## Goal

Select the worker idle/parking and wake-up protocol that should feed the later
R1 scheduler without reopening already-qualified queue, task-representation or
worker-scheduling decisions.

R0.4 starts from the R0.3 contract:

```text
queue:
    containers.WorkStealingDeque!(TaskRef, Capacity)

TaskRef:
    8-byte non-owning shared(TaskHeader)*

victim selection:
    deterministic round-robin

searching workers before parking:
    all idle workers may search

continuation:
    AArch64:
        saturation-gated direct-one
    x86_64 and other currently qualified targets:
        enqueue-all

overflow:
    execute-inline fallback
```

## Questions

R0.4 must determine:

- how long an idle worker should actively search before blocking;
- whether a yield phase is useful between search and park;
- how to avoid lost wakeups;
- whether wake-one is sufficient for ordinary task publication;
- when wake-many is required;
- how shutdown wakes parked workers;
- whether native platform wait primitives materially outperform a portable
  condition-variable baseline;
- how active-searcher limits should interact with real parking;
- whether the answer differs materially between x86_64 and AArch64.

## Required properties

Any selected protocol must preserve:

- no lost tasks;
- no duplicate execution;
- no lost wakeups;
- no indefinitely parked worker while runnable work exists and progress
  requires that worker;
- clean shutdown;
- bounded synchronization state;
- no allocation on the worker idle/wake hot path;
- narrow reviewable unsafe/platform boundary;
- DMD correctness and LDC optimized performance.

Faster wake latency with weaker shutdown or wakeup semantics is not an
optimization.

## Candidate families

### A — portable condition-variable baseline

Build a portable baseline using D runtime synchronization primitives.

The baseline must make the state predicate explicit and must use the condition
variable only as the blocking mechanism, not as the source of truth.

Measure:

- idle CPU consumption;
- park count;
- wake count;
- spurious wake count where observable;
- publication-to-execution latency;
- throughput impact under intermittent work.

### B — two-phase idle protocol

Compare:

1. search -> park;
2. search -> yield -> park;
3. bounded spin/search -> yield -> park.

The active phase must be bounded.

Do not busy-spin indefinitely.

### C — wake policy

Compare:

- wake-one for ordinary publication;
- wake-many for burst publication;
- explicit wake-all for shutdown.

The scheduler must not rely on queue-size snapshots for correctness.

### D — active-searcher interaction

R0.3 found that limiting searchers without parking reduced failed-steal traffic
but did not improve throughput.

Revisit:

- all idle workers may search;
- one designated active searcher;
- bounded active searchers;

this time with non-searching workers actually parkable.

The searcher-state protocol must participate in lost-wakeup reasoning.

### E — native platform primitives

After the portable protocol is correct, compare native wait/wake primitives
only where justified by evidence.

Potential targets include:

- Linux futex;
- Windows WaitOnAddress / WakeByAddressSingle;
- other platform primitives only if required by supported targets.

Native code must remain behind a narrow abstraction boundary.

Do not assume native primitives are faster before measuring them.

## Qualification sequence

### P01 — condition-variable baseline

Build a scheduler-neighborhood idle protocol around the selected R0.3 worker
scheduler.

Required scenarios:

- workers start idle and receive one task;
- one producer publishes repeated isolated tasks;
- burst publication;
- recursive/irregular scheduler work followed by idle;
- repeated idle -> work -> idle transitions;
- shutdown with all workers parked;
- shutdown while work is still completing.

Required evidence:

- exact task/accounting checks;
- wake latency distribution;
- idle CPU observation;
- no deadlock/lost wakeup in repeated stress.

Exit criterion:

- establish a correct portable blocking baseline.

### P02 — two-phase search/yield/park

Compare bounded active-search durations.

At minimum:

- immediate park after failed search phase;
- one or more yield rounds before park;
- short bounded active-search budget before yield/park.

Measure both:

- wake-to-execute latency;
- idle CPU cost.

Exit criterion:

- select a transition only if it improves the latency/CPU trade without
  weakening correctness.

### P03 — wake-one versus burst wake

Measure:

- isolated single-task publication;
- small bursts;
- bursts larger than one worker;
- recursive fanout after idle.

Compare:

- wake-one;
- bounded wake count;
- wake-all where justified.

Exit criterion:

- establish explicit publication wake rules.

### P04 — parked-searcher protocol

Revisit active-searcher limits together with parking.

Compare:

- all awakened workers searching;
- one searching worker with others parked;
- bounded N searchers.

Required correctness:

- no stranded work;
- no lost wakeup when searcher state changes;
- progress under producer/worker races.

### P05 — native wait primitive comparison

Compare the selected portable protocol against native primitives on available
platforms.

Required:

- local native x86_64/XPS;
- native AArch64 Linux;
- DMD correctness where supported;
- LDC optimized performance.

Cross-compilation is not equivalent to native runtime qualification.

### P06 — combined parking/wake policy

Combine only individually supported choices.

Run:

- isolated wake-latency workload;
- intermittent/bursty workload;
- recursive workload;
- irregular workload;
- prolonged idle CPU observation;
- repeated shutdown stress.

### P07 — parking/wake decision

Record:

- active-search budget;
- yield policy;
- park predicate/state machine;
- wake-one/wake-many rules;
- shutdown wake rule;
- platform abstraction boundary;
- architecture/platform specialization if required.

## Correctness model

The wait primitive is never the scheduler state.

A worker must decide whether it may sleep from scheduler-owned state under an
explicit protocol that closes the publication/parking race.

R0.4 must document the state machine and happens-before edges before selecting
a production candidate.

At minimum reason about races between:

- producer publishes task / worker prepares to sleep;
- producer wakes / worker has not yet blocked;
- worker changes searching/parked state;
- shutdown flag publication / worker park;
- multiple producers waking one or more workers.

## Performance policy

Primary measurements:

- publication-to-start latency;
- steady-state task throughput;
- idle CPU utilization;
- park/wake frequency;
- failed search work before park.

Report distributions where wake latency is relevant; a single median is not
sufficient.

Local XPS remains the primary native x86_64 performance environment.

Native AArch64 evidence is required before R0.4 closes.

Hosted CI performance numbers are supporting evidence only.

## Benchmark-methodology rule from R0.3

Do not compare separately compiled semantic duplicates when the selected
implementation itself can be measured directly.

Compiler/module/function-shape effects are retained as a known source of
scheduler benchmark noise.

Repeated native runs and spread/percentiles must be recorded.

## Non-goals

R0.4 does not freeze:

- allocator/pool topology -> R0.5;
- public Scheduler API -> R1;
- WorkerPool API -> R1;
- TaskScope -> R1;
- cancellation -> R1;
- typed result/future API -> R1.

## Exit criterion

R0.4 passes when one parking/wake contract is selected with:

- explicit lost-wakeup-safe state protocol;
- explicit spin/search/yield/park transition;
- explicit wake-one/wake-many/shutdown rules;
- idle CPU and wake-latency evidence;
- scheduler-neighborhood correctness;
- local XPS qualification;
- native AArch64 qualification;
- narrow platform-specific boundary where needed;
- deferred allocation/public-API questions clearly preserved.
