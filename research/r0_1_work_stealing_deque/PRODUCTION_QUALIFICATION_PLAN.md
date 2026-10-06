# R0.1 — Production-Neighbourhood Qualification Plan

## Purpose

R0.1 architecture selection is complete.

Selected research architecture:

    P08e marked-top bounded batch work-stealing deque

This plan defines the remaining qualification required before deciding whether
the selected mechanism may be promoted from research into a production-near
internal primitive or reusable container.

Architecture selection and production promotion are deliberately separate
decisions.

## Current status

Research architecture selection:

    PASS

Preferred research candidate:

    P08e marked-top bounded batch work-stealing deque

Production-neighbourhood qualification:

    OPEN

Public API promotion:

    NOT AUTHORIZED

Cross-repository ownership decision:

    OPEN

## Qualification principles

The following rules apply throughout this phase.

1. Preserve all R0.1 research evidence and rejected alternatives.
2. Do not weaken semantics to improve benchmark results.
3. Do not compare implementations performing materially different work.
4. Measure LDC optimized performance explicitly.
5. Retain DMD as a correctness and code-generation qualification compiler.
6. Keep scheduler policy separate from generic deque mechanics where possible.
7. Keep unsafe atomic/pointer implementation details inside the smallest
   reviewable boundary.
8. Do not move the implementation into `containers-d` until the ownership
   decision gate is reached.
9. A faster design with weaker lifetime, safety, or ordering guarantees is not
   an optimization.
10. Failed experiments remain research evidence and must not be erased merely
    because they are not selected.

## Gate sequence

The gates are intentionally ordered.

Later scheduler benchmarks must not become the mechanism for discovering basic
container-contract or lifetime defects.

---

## P09 — Bounded occupancy and near-capacity qualification

### Goal

Close the owner-local gaps still listed in `BENCHMARK_PLAN.md`.

### Required workloads

Measure at stable occupancies such as:

    1 / 8 capacity
    1 / 4 capacity
    1 / 2 capacity
    3 / 4 capacity
    capacity - 1
    capacity

Include:

- repeated push/pop while preserving occupancy;
- transitions into full;
- failed push while full;
- recovery after pop;
- repeated near-capacity cycling;
- owner-only operation;
- owner plus thief activity near capacity.

### Correctness checks

Verify:

- no overwrite of live entries;
- no false-full result below capacity;
- no successful push beyond capacity;
- correct recovery from full to non-full;
- accounting remains exact;
- batch stealing near capacity does not change owner-visible invariants.

### Performance checks

Record:

- ns/op;
- throughput;
- p10/median/p90;
- owner retry counts where meaningful;
- comparison with the modular single-steal baseline;
- comparison with Taskflow where semantics are equivalent.

### Exit criteria

P09 passes when bounded occupancy and near-capacity behaviour are both
correct and no unexplained material performance cliff exists.

---

## P10 — Element and lifetime contract

### Goal

Replace value-only research assumptions with an explicit scheduler-relevant
element contract.

### Questions to resolve

Determine whether the deque stores:

- a pointer-sized task reference;
- a two-word `TaskRef`;
- another trivially movable representation.

Specify:

- ownership;
- lifetime;
- publication;
- removal;
- reuse;
- destruction;
- whether null/default values are meaningful;
- whether the element may contain GC references;
- whether the hot path must remain `@nogc`;
- whether copying is permitted;
- whether moving is required;
- whether the element requires destructors or postblit behaviour.

### Required probes

Qualify at minimum:

- pointer-sized element;
- representative two-word task handle if still architecturally relevant;
- compile-time rejection of unsupported element categories;
- no duplicate destruction or lifetime extension;
- safe reuse of slots after steal/pop.

### Exit criteria

P10 passes only when the supported element category is explicit enough that
the implementation no longer depends on accidental `size_t` properties.

---

## P11 — Safety boundary

### Goal

Define the smallest unsafe implementation boundary and the callable contract
above it.

### Required decisions

Document:

- which methods may be `@safe`;
- which implementation regions require `@trusted`;
- which atomic operations require raw/shared access;
- whether returned task references borrow, own, or transfer ownership;
- which preconditions cannot be expressed in the type system.

The central concurrency precondition remains:

    exactly one owner
    zero or more thieves

The API must not imply that arbitrary threads may call owner operations.

### Negative qualification

Add compile-time or runtime-negative probes where useful for:

- unsupported element types;
- unsafe lifetime escape;
- invalid ownership use where detectable;
- accidental copying of queue state;
- invalid capacity/template parameters.

### Exit criteria

P11 passes when users of the internal primitive do not need to perform raw
atomic or pointer manipulation themselves.

---

## P12 — Bounded-overflow policy

### Goal

Separate deque mechanics from scheduler behaviour when the local queue fills.

### Candidate policies

Research separately:

- global injection queue;
- sharded spill queue;
- execute-inline fallback;
- handoff to another worker;
- hybrid policy.

### Important constraint

Do not put a resizing mechanism into the local work-stealing deque merely to
avoid defining scheduler overflow policy.

The selected R0.1 local deque remains bounded unless new evidence justifies an
architecture change.

### Required measurements

Measure:

- full-queue frequency;
- overflow latency;
- throughput under burst production;
- contention introduced by shared overflow structures;
- effect on worker locality;
- effect on allocation behaviour.

### Exit criteria

P12 passes when queue-full behaviour is explicit and does not silently corrupt
the local deque hot path.

---

## P13 — Minimal scheduler harness

### Goal

Build the smallest scheduler environment capable of exercising realistic
production-neighbourhood behaviour without prematurely defining the public
Executor/Task API.

### Minimum model

Include:

- N workers;
- one local P08e deque per worker;
- owner-local push/pop;
- stealing from other workers;
- batch transfer;
- deterministic task payload;
- worker startup/shutdown;
- bounded overflow policy from P12;
- accounting;
- checksum validation.

Do not yet require:

- public executor API;
- fibers;
- I/O integration;
- cancellation API;
- final parking policy.

### Required observability

Record:

- tasks executed;
- local pops;
- steals;
- batch claims;
- stolen tasks per claim;
- failed steal attempts;
- owner busy retries;
- overflow events;
- work distribution;
- wall time.

### Exit criteria

P13 passes when the selected deque behaves correctly as part of a minimal
multi-worker scheduler rather than only as an isolated queue.

---

## P14 — End-to-end scheduler workloads

### Goal

Close the end-to-end synthetic workloads required by `BENCHMARK_PLAN.md`.

### Required workloads

#### P14.1 Recursive fork/join tiny tasks

Exercise:

- frequent local task creation;
- depth;
- work-first locality;
- stealing under imbalance.

#### P14.2 Fine tasks

Scheduling overhead dominates or is a large fraction of total work.

#### P14.3 Medium tasks

Queue overhead and useful work are both significant.

#### P14.4 Coarse tasks

Useful work dominates.

The scheduler must not regress materially merely because batching is less
important.

#### P14.5 Irregular task production

Exercise:

- bursty task creation;
- uneven worker load;
- changing victim pressure;
- intermittent empty queues;
- overflow path activation.

### Comparisons

At minimum compare:

- D single-steal scheduler control;
- P08e batch scheduler;
- semantically equivalent Taskflow control where feasible.

Do not claim language superiority from scheduler-policy differences.

### Metrics

Primary:

- total wall time;
- tasks/s;
- scaling versus worker count;
- ns/task where meaningful.

Diagnostic:

- local-pop ratio;
- steal ratio;
- batch utilization;
- retries;
- overflow events;
- CPU distribution;
- optional hardware counters.

### Exit criteria

P14 passes when P08e remains correct and competitive across fine through coarse
work without a severe scheduler-policy regression.

---

## P15 — Additional architecture/runtime coverage

### Goal

Reduce the current asymmetry between x86_64 runtime evidence and AArch64
code-generation-only evidence.

### Required work

Prefer native AArch64 execution.

At minimum repeat:

- core correctness;
- last-item race;
- multi-thief accounting;
- marked-top batch overlap;
- scheduler-like performance;
- end-to-end scheduler workload.

If native hardware is not available, record that limitation explicitly.

Do not treat cross-compilation/code-generation inspection as equivalent to
native runtime qualification.

### Exit criteria

P15 passes when at least one additional architecture has meaningful runtime
evidence or when promotion explicitly remains architecture-limited.

---

## P16 — Ownership and promotion decision

### Goal

Decide where the qualified implementation belongs.

### Candidate A — containers-d

Promote only if the resulting abstraction is scheduler-independent.

Required characteristics include:

- generic element contract;
- clear lifetime semantics;
- reusable single-owner/multi-thief contract;
- capacity semantics independent of scheduler policy;
- generic batch semantics;
- documented memory-ordering contract;
- safe reusable boundary;
- no dependency on concurrency-d task lifecycle.

### Candidate B — concurrency-d internal primitive

Keep internal if best performance or correctness depends materially on:

- `TaskRef`;
- scheduler-owned lifetime;
- worker-local assumptions;
- scheduler-specific batch consumption;
- overflow policy;
- task-state invariants;
- executor coordination.

### Required action

At this gate, update the existing `containers-d` ownership tracker with the
qualified evidence and decision.

Do not create a dependency from concurrency-d to containers-d before this gate
passes.

### Exit criteria

P16 produces one explicit decision:

    PROMOTE TO containers-d

or:

    KEEP INTERNAL TO concurrency-d

with rationale and evidence links.

---

## Promotion gate

The selected research candidate may move toward production only when:

    P09 PASS
    P10 PASS
    P11 PASS
    P12 PASS
    P13 PASS
    P14 PASS

and architecture limitations from P15 are explicitly resolved or accepted.

P16 then determines repository ownership.

## Non-gates

The following alone are not sufficient for promotion:

- one strong microbenchmark;
- x86_64 code-generation quality;
- passing stress tests;
- Taskflow parity;
- batch speedup;
- successful GenMC modelling;
- one compiler passing;
- a scheduler demo.

Promotion requires the combined contract.

## Immediate next step

Begin with:

    P09 — bounded occupancy and near-capacity qualification

Do not start the public Task or Executor API as part of P09.

The purpose of P09 is to finish qualification of the selected deque mechanics
before introducing additional scheduler policy.
