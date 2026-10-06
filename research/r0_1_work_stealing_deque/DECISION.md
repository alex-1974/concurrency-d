# R0.1 — Work-Stealing Deque Research Decision

## Status

R0.1 has reached an architecture-selection decision.

The preferred research candidate for the first concurrency-d CPU scheduler is:

    P08e marked-top bounded work-stealing deque with bounded batch stealing

This decision selects the mechanism for the next qualification stage.

It does **not** yet promote the research implementation to a public API or
production container.

## Selected architecture

The preferred candidate has these defining properties:

- fixed power-of-two bounded storage;
- exactly one owner;
- zero or more thieves;
- owner push/pop at the bottom;
- thieves steal from the top;
- cache-line separation of contended indices;
- modular counter arithmetic;
- 63-bit logical top domain plus one explicit busy marker bit;
- single-item steal support;
- bounded batch steal;
- one top reservation for a transferred batch;
- owner detects a batch reservation from top state alone;
- no separate owner-side coordination gate;
- no pre-claim read of the owner-mutated bottom cache line merely to classify
  batch-busy state.

The current research implementation is:

    candidate/source/concurrency/research/
        modular_bounded_wsq_batch_marked_top.d

## Why P08e was selected

### Correctness

The research establishes:

- owner LIFO behaviour;
- thief FIFO behaviour;
- exactly-one-winner last-item handling;
- no duplicate return in the exercised concurrent cases;
- accounting preservation;
- bounded slot selection;
- modular wraparound qualification;
- multi-thief qualification;
- batch correctness under forced overlap.

### Memory ordering

P08f documents the marked-top ordering protocol.

Evidence includes:

- x86_64 optimized code-generation inspection;
- AArch64 code-generation inspection;
- RC11 / GenMC modelling;
- negative controls that expose the failure when required ordering is weakened.

This is stronger evidence than treating the implementation as correct merely
because stress tests happen to pass.

### Owner hot path

The marked-top design retains the previously qualified owner-side RMW/barrier
mechanism and does not impose the global gate cost observed in P08d.

The gated batch design was rejected because it materially degraded owner
performance and concurrent drain behaviour.

### Batch performance

P08e amortizes synchronization across multiple stolen tasks.

Scheduler-like measurements with batch size 8 showed large improvements over
single-item stealing when tasks are fine grained.

### External C++ reference

P08h compared the same scheduler-like workload against pinned Taskflow
`tf::BoundedWSQ`.

Pinned Taskflow commit:

    bbd7251d577b33a4aeff434ce5f5569b94d4cc48

Four alternating paired runs gave median-of-run medians:

    work=0
        Taskflow single = 69.174 ns/item
        D single        = 63.221 ns/item
        P08e batch      = 15.915 ns/item

    work=16
        Taskflow single = 72.340 ns/item
        D single        = 67.941 ns/item
        P08e batch      = 17.947 ns/item

    work=64
        Taskflow single = 69.559 ns/item
        D single        = 68.858 ns/item
        P08e batch      = 33.721 ns/item

The D single-steal implementation therefore belongs to approximately the same
performance class as the established C++ Taskflow reference on this host and
workload.

The larger P08e improvement is architectural rather than a D-versus-C++
language comparison.

Measured Taskflow/P08e speedups were approximately:

    work=0   4.35x
    work=16  4.03x
    work=64  2.06x

## Rejected or non-preferred alternatives

### Signed-counter baseline

Useful as a reference implementation.

Rejected as the preferred mechanism because signed-overflow assumptions do not
provide the desired explicit modular wraparound contract.

### Modular single-steal baseline

Retained as an important control and fallback reference.

It reaches approximately Taskflow-level scheduler performance, but does not
capture the synchronization amortization available from batch stealing.

### Global-gated batch design — P08d

Correctness was demonstrated, but the architecture was rejected.

The global gate:

- raised owner pop cost materially;
- raised push/pop pair cost;
- produced poor concurrent-drain performance.

The cost is structural rather than a minor code-generation issue.

### Full64 distance-marker design — P08g

P08g preserves the complete 64-bit counter domain and passed substantial
correctness qualification.

It initially reached pure-drain performance parity with P08e.

However, scheduler-like testing exposed approximately:

    work=0    +9.04 %
    work=16  +19.91 %
    work=64   -0.15 %

relative normalized cost versus P08e.

P08g requires observation of both top state and bottom to distinguish its busy
state while preserving every 64-bit logical top value.

P08g6 isolated the resulting owner/thief coherence cost:

    LDC:
        P08e busy reject   = 0.520 ns/op
        Full64 busy reject = 2.009 ns/op

The extra counter bit does not justify this scheduler-hot-path cost.

P08g remains valuable research and should not be deleted.

## Counter-domain decision

P08e uses one state bit from the 64-bit top representation.

The effective logical top domain is therefore 63-bit modular.

This is an intentional engineering trade-off:

    cheaper and locally recognizable busy state

is preferred over:

    preserving the final logical counter bit while requiring bottom-dependent
    state classification.

The supported counter-domain contract must remain explicit in any promoted
implementation.

## What R0.1 has established

The research has established enough evidence to choose an architecture.

Evidence includes:

- sequential behaviour;
- last-item race;
- multi-thief accounting;
- wraparound;
- modular counter representation;
- layout qualification;
- DMD and LDC code-generation inspection;
- owner hot-path microbenchmarks;
- single-thief contention;
- multi-thief contention;
- naive batch correctness failure;
- gated batch correctness and performance;
- marked-top batch correctness;
- marked-top scheduler-like performance;
- x86_64 ordering code generation;
- AArch64 ordering code generation;
- RC11 model checking;
- Full64 alternative qualification and rejection as preferred candidate;
- external Taskflow scheduler-level comparison.

## What R0.1 has not yet established

Architecture selection must not be confused with production qualification.

The current `BENCHMARK_PLAN.md` still contains qualification areas that have
not been comprehensively closed.

### Remaining performance qualification

Still required or insufficiently covered:

- steady-state bounded occupancy;
- near-capacity owner operation;
- recursive fork/join synthetic workload;
- fine-task end-to-end scheduler workload;
- medium-task end-to-end scheduler workload;
- coarse-task end-to-end scheduler workload;
- irregular task-production workload.

P08e5/P08h provide scheduler-like drain evidence, but they are not a complete
scheduler implementation and therefore do not replace these end-to-end gates.

### Additional architecture coverage

x86_64 runtime performance is strongly qualified.

AArch64 currently has code-generation evidence, not equivalent native runtime
performance evidence.

### Element contract

R0.1 primarily qualifies queue mechanics using simple value/task-reference
surrogates.

Before reusable promotion, the exact element representation and ownership /
lifetime requirements must be fixed.

### Public safety boundary

The eventual promoted implementation must expose a documented safe boundary
while keeping raw atomic and pointer mechanics inside the smallest reviewable
implementation region.

### Overflow policy

The local deque is bounded.

The scheduler-level policy for local-queue-full behaviour remains outside this
R0.1 architecture selection and must be qualified separately.

## Promotion decision

Do not publish the current candidate as a public container API yet.

The next stage should treat P08e as the selected internal scheduler primitive
and perform production-neighbourhood qualification around it.

After that qualification, decide ownership:

### Promote to containers-d if

the final deque contract is genuinely scheduler-independent, including:

- element/lifetime semantics;
- single-owner/multi-thief preconditions;
- capacity semantics;
- batch semantics;
- memory-ordering contract;
- safe reusable boundary.

### Keep internal to concurrency-d if

optimal behaviour depends materially on scheduler-specific:

- TaskRef representation;
- worker-local policy;
- batch-transfer semantics;
- overflow handling;
- scheduling/lifetime invariants.

The existing containers-d ownership tracker remains the coordination point for
that decision.

## R0.1 decision

Research architecture selection:

    PASS

Preferred candidate:

    P08e marked-top bounded batch work-stealing deque

Production/public promotion:

    NOT YET

Next phase:

    production-neighbourhood and end-to-end scheduler qualification

The research branch and all rejected candidates, controls, formal evidence,
code-generation evidence, raw benchmark results, and external-reference
comparisons must be preserved.
