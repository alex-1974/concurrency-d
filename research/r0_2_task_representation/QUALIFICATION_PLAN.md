# R0.2 — Task Representation Qualification Plan

Status: PASS — R0.2 CLOSED

## Goal

Select the internal task-reference and task-record representation that should
feed R0.3 worker scheduling without prematurely freezing a public task API.

R0.2 must determine:

- the hot queue element representation;
- where the execute target lives;
- how type erasure is represented;
- the minimum TaskRecord header needed by the scheduler;
- the lifetime boundary required for stack-resident and externally owned tasks;
- which questions remain intentionally deferred to R0.5 allocation research.

The result must preserve the qualified R0.1 queue contract:

```d
containers.WorkStealingDeque!(TaskRef, Capacity)
```

with a trivial shared-compatible queue element.

## Existing evidence carried forward

R0.1 P10 already established:

- preferred queue element size: 8 bytes;
- preferred form: non-owning `shared(TaskRecord)*` handle;
- 16-byte trivial queue elements were mechanically correct but approximately
  56% slower than 8-byte handles in the LDC batch-drain probe;
- queue storage does not own or reclaim TaskRecord;
- referenced storage must outlive every queued or in-flight TaskRef;
- GC class references and ordinary unshared pointers are outside the selected
  queue-element contract.

R0.2 must not reopen those facts without contradictory evidence.

## Candidate families

### A — pointer-only TaskRef

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
}
```

The execute target is reachable through TaskRecord metadata.

Expected advantages:

- 8-byte queue element;
- smallest queue/cache footprint;
- one transport representation for all task kinds;
- execution metadata remains with the record.

Potential cost:

- one dependent metadata load before indirect dispatch.

### B — pointer + execute-function TaskRef

Conceptually:

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}
```

Expected advantage:

- execute target may be available directly from the dequeued value.

Known concern:

- 16-byte queue element;
- R0.1 already measured a substantial 16-byte queue-transfer cost;
- D shared-publication compatibility must be proven for the function-pointer
  field rather than assumed.

This candidate survives only if it demonstrates a concrete end-to-end benefit.

### C — pointer-only + D-native compact discriminator

A pointer-only queue handle with execution selected from compact immutable
record metadata, for example a small discriminator feeding a specialized
dispatch table or switch.

This is not assumed superior. It exists to test whether D compile-time
specialization can beat a generic indirect function call for a bounded task
family without leaking scheduler policy into the queue.

### D — stack-resident structured task record

This is a lifetime/storage variant, not necessarily a distinct TaskRef format.

R0.2 must prove which TaskRecord header can safely refer to stack-resident
structured work while its owning scope guarantees lifetime.

### E — pooled task record

This is also primarily a lifetime/storage variant.

R0.2 should define the representation requirements a future pool must satisfy,
but allocator/pool design belongs to R0.5 and must not be pulled forward.

## Qualification sequence

### P01 — representation capability and layout

Measure and compile-check:

- size/alignment;
- elaborate copy/assignment/destructor traits;
- containers-d queue compatibility;
- null/default representation;
- shared-pointer compatibility;
- function-pointer field compatibility;
- basic move/copy properties of the handle itself.

Exit criterion:

- establish which candidate references are mechanically legal queue elements
  on DMD 2.111 and LDC 1.41;
- retain 8-byte pointer-only as baseline.

### P02 — dispatch kernel

Compare execution overhead independently of allocation and queue contention:

- pointer-only record-stored execute target;
- pointer + execute target in TaskRef, if P01 admits it;
- one compact D-native discriminator/table variant if mechanically coherent.

Measure:

- homogeneous task stream;
- alternating two-type stream;
- mixed multi-type stream;
- tiny and non-trivial task bodies;
- DMD correctness;
- LDC optimized performance;
- generated code where differences require explanation.

Exit criterion:

- determine whether any larger TaskRef produces enough dispatch benefit to
  justify its queue-transfer penalty.

### P03 — record-header and cache locality

Characterize the minimum scheduler-visible TaskRecord header.

Separate hot scheduling metadata from cold task payload/result state.

Measure at least:

- record header size/alignment;
- records per 64-byte cache line;
- sequential task dispatch;
- pointer-chasing with shuffled records;
- false-sharing risk for fields later mutated by different workers.

Do not add cancellation/result/scope fields merely because R1 may need them.

### P04 — structured lifetime model

Qualify the pointer-only TaskRef with:

- externally owned stable record;
- stack-resident record whose scope joins before destruction;
- handoff through the work-stealing deque;
- completion before lifetime end.

Required negative cases should demonstrate that escaping a structured record
past its scope is a contract violation or statically rejected where practical.

This gate defines lifetime semantics; it does not build TaskScope yet.

### P05 — scheduler-neighborhood integration

Repeat representative scheduler work using the selected R0.2 representation
on top of the production containers-d deque.

At minimum:

- flat fine/medium work;
- recursive/fork-join;
- irregular graph.

Compare against the R0.1 value-handle scheduler baselines only where semantics
are matched.

### P06 — ownership decision

Produce the selected internal TaskRef/TaskRecord contract for R0.3.

Explicitly record what remains deferred:

- allocator/pool implementation -> R0.5;
- TaskScope implementation -> R1;
- cancellation state -> R1;
- typed result storage -> R1;
- public Task API -> R1;
- parking/wake -> R0.4.

## Performance policy

LDC 1.41 is the optimized-performance baseline.

DMD 2.111 remains a correctness and code-shape requirement.

A representation is not accepted merely because an isolated dispatch loop is
faster. It must preserve or improve scheduler-neighborhood performance while
keeping lifetime and shared-publication semantics at least as strong.

## Architecture policy

Native x86_64 is the primary local performance environment.

Before R0.2 closes, the selected representation must also receive meaningful
native AArch64 runtime coverage because pointer publication, indirect dispatch,
and cache behavior can differ materially from x86_64.

## Non-goals

R0.2 does not freeze:

- public Task names;
- TaskScope;
- result/future API;
- cancellation API;
- task allocator;
- pool topology;
- worker scheduling policy.

## Exit criterion

R0.2 passes when one internal task representation is selected with:

- explicit layout;
- explicit lifetime contract;
- queue compatibility;
- dispatch evidence;
- scheduler-neighborhood evidence;
- DMD/LDC qualification;
- native AArch64 coverage;
- clearly deferred ownership/allocation questions.


## Final selected contract

R0.2 closed with:

```text
TaskRef
    8-byte non-owning shared(TaskHeader)*

TaskHeader
    8-byte execute target
    initialized before publication
    read through the qualified shared metadata path
```

Structured stack-resident records are permitted only under join-before-return
ownership.

Allocator/pool design remains deferred to R0.5.

TaskScope, cancellation, typed results and the public Task API remain deferred
to R1.

The complete decision is recorded in:

```text
results/p06-task-representation-decision.md
```

R0.3 worker-scheduling research must treat this as the internal baseline unless
new contradictory evidence appears.
