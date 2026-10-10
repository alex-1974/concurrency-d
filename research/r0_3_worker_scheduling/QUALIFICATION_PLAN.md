# R0.3 — Worker Scheduling Qualification Plan

Status: ACTIVE RESEARCH

## Goal

Select the worker-side scheduling policy that should feed R0.4 parking/wake
research and later R1 scheduler construction.

R0.3 starts from already-qualified lower layers:

```text
queue:
    containers.WorkStealingDeque!(TaskRef, Capacity)

TaskRef:
    8-byte non-owning shared(TaskHeader)*

TaskHeader:
    8-byte execute target
```

R0.3 must compare scheduling policy without reopening queue ownership,
TaskRef layout, allocator design, or parking primitives.

## Questions

R0.3 must determine:

- how a worker selects victims;
- whether a successful victim should remain sticky;
- whether randomization improves contention/load balance;
- how many workers should be allowed to search concurrently;
- when a freshly spawned continuation should execute directly rather than be
  queued;
- how those choices interact with single-item versus batch stealing;
- whether compiler/architecture differences materially change the result.

## Candidate families

### A — victim selection

Compare at least:

1. deterministic round-robin baseline;
2. per-worker pseudo-random victim selection;
3. sticky-success victim selection:
   - continue probing the last successful victim for a bounded number of
     attempts;
   - fall back to randomized or round-robin search after failure.

The random generator must be per-worker, allocation-free and deterministic
when seeded for reproducible probes.

### B — searching-worker bound

Current scheduler-like research allows all idle workers to search.

Compare:

1. unbounded/all-idle searching baseline;
2. at most one active searcher;
3. a small bounded searcher count derived from worker count.

This gate deliberately stops before parking.

Workers that are not allowed to search may yield/spin in the probe, but R0.3
must not select a platform wait primitive. That belongs to R0.4.

### C — continuation/direct-execution fast path

Compare at least:

1. enqueue all spawned children;
2. enqueue one child and execute one child directly;
3. direct-execute only under a bounded/local condition if evidence justifies
   it.

The policy must preserve structured outstanding-count semantics.

Do not silently weaken fairness or permit recursive stack blow-up.

### D — steal width policy

R0.1 established that batch stealing is workload dependent.

R0.3 may use:

- single steal;
- batch steal;
- a simple scheduling-level selector if evidence supports it.

The queue primitive itself remains policy-free.

## Qualification sequence

### P01 — policy baseline

Build one common scheduler-neighborhood harness on the selected R0.2 TaskRef.

Required workloads:

- flat fine/medium/coarse;
- recursive fork/join;
- irregular graph.

Use:

- production containers-d deque;
- fixed worker affinity where available;
- exact task/accounting checksums;
- no parking;
- no allocator/pool experiment.

Exit criterion:

- establish a reproducible baseline for policy-only comparisons.

### P02 — victim selection

Compare round-robin, random and sticky-success policies.

Measure:

- ns/task;
- steal attempts;
- successful claims;
- failed steals;
- tasks stolen per claim;
- victim-switch count;
- per-worker execution range;
- owner-local ratio where meaningful.

Required workloads:

- flat work=0/16/64;
- recursive;
- irregular.

Exit criterion:

- reject policies that only win one synthetic case while causing a severe
  regression elsewhere.

### P03 — bounded searching workers

Introduce a scheduler-owned searching-worker token/count.

Compare:

- all idle workers searching;
- one active searcher;
- bounded N searchers.

Measure both:

- productive throughput;
- wasted steal/search attempts.

No sleeping/condition-variable/futex logic is admitted here.

Exit criterion:

- determine whether limiting concurrent search reduces contention without
  starving available work.

### P04 — continuation/direct execution

Compare enqueue-all against a bounded continuation/direct-execution path.

Required correctness:

- exact task count;
- exact spawn count;
- no duplicate execution;
- no task loss;
- bounded stack behavior;
- correct outstanding completion.

Measure recursive and irregular workloads first; flat workloads are secondary.

Exit criterion:

- select a fast path only if it improves scheduler-neighborhood performance
  without weakening lifetime or fairness semantics.

### P05 — combined scheduler policy

Combine only individually supported policy choices.

Run the combined candidate against the P01 baseline on:

- DMD 2.111 correctness;
- LDC 1.41 optimized performance;
- local XPS native x86_64;
- native AArch64 / Neoverse-N2.

Compare against retained R0.2 scheduler-neighborhood evidence where semantics
remain matched.

### P06 — worker-scheduling decision

Record the selected internal policy contract for R0.4/R1.

Explicitly defer:

- condition variables / futex / WaitOnAddress / platform waits -> R0.4;
- allocator/pool topology -> R0.5;
- public Scheduler/WorkerPool API -> R1;
- cancellation -> R1;
- typed results -> R1.

## Performance policy

LDC 1.41 is the optimized-performance baseline.

DMD 2.111 remains a correctness and code-shape requirement.

Policy comparisons must use identical:

- queue implementation;
- TaskRef/TaskHeader representation;
- task graph;
- work function;
- worker count;
- affinity;
- compiler/build mode.

A faster policy with weaker completion/fairness semantics is not an
optimization.

## Architecture policy

Native x86_64 on the project XPS remains the primary local performance
qualification environment.

Native AArch64 runtime evidence is required before R0.3 closes.

Hosted CI performance numbers are supporting evidence only.

## Non-goals

R0.3 does not freeze:

- public Scheduler API;
- WorkerPool API;
- TaskScope;
- cancellation;
- result/future API;
- parking primitive;
- allocator or task pool.

## Qualification progress

### P01 — PASS

Baseline scheduler-neighborhood harness qualified on:

- DMD 2.111;
- LDC 1.41 hosted x86_64;
- native AArch64 / Neoverse-N2.

### P02 — PASS

Victim-selection decision:

```text
deterministic round-robin
```

Random and sticky-success remain retained alternatives/negative evidence.

### P03 — PASS

Searching-worker decision for the pre-parking scheduler:

```text
all idle workers may search
```

One/bounded active searchers reduce failed-steal traffic but do not provide a
robust throughput improvement without parking.

### P04 — PASS

Continuation policy is architecture-specialized at compile time:

```text
AArch64:
    saturation-gated direct-one

other currently qualified targets:
    enqueue-all
```

Generic direct-one and generic saturation/headroom thresholds are retained as
negative or architecture-specific evidence.

### P05 — CI REQUALIFYING / LOCAL XPS RERUN PENDING

The first local XPS run correctly rejected a separately compiled duplicate
x86 candidate. The selected x86 policy is now qualified through the unchanged
P01 enqueue-all executable itself, avoiding a code-layout confound.

Native AArch64 continues to qualify the saturation-gated continuation
candidate against P01.

The local XPS runner is:

```text
research/r0_3_worker_scheduling/tools/run_p05_xps.sh
```

P05 becomes complete only after the corrected selected-implementation CI and
local XPS evidence are recorded.

### P06 — PENDING

Final worker-scheduling decision follows the local XPS P05 gate.

## Exit criterion

R0.3 passes when one worker-scheduling policy is selected with:

- explicit victim-selection rule;
- explicit searching-worker rule;
- explicit continuation/direct-execution rule;
- scheduler-neighborhood correctness;
- flat/recursive/irregular performance evidence;
- DMD/LDC qualification;
- local XPS qualification;
- native AArch64 qualification;
- clearly deferred parking/allocation/public-API questions.
