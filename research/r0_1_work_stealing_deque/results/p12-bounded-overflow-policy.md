# R0.1 P12 — Bounded Overflow Policy

## Status

    PASS

P12 determines scheduler behaviour when the selected bounded local
work-stealing deque is full.

The local deque remains bounded.

P12 does not add resizing to the local deque.

## Question

When:

    local.tryPush(task) == false

the scheduler must choose a policy.

The qualified candidates were:

    retry until local space exists
    execute task inline
    global locked spill queue
    sharded locked spill queues

The purpose of P12 was not to design a final public scheduler API.

It was to identify an explicit production-neighbourhood overflow policy before
building the minimal scheduler harness in P13.

## P12a — Retry versus execute-inline baseline

P12a established the first controlled overflow baseline.

The synchronized LDC result for very small work was approximately:

    retry   = 5.625 ns/task
    inline  = 5.501 ns/task

Inline was only slightly faster for this workload.

However, inline execution materially changes scheduling behaviour because the
producer executes tasks instead of waiting for local queue capacity.

This prevented selecting inline solely from the P12a microbenchmark.

## P12b — Work granularity

P12b repeated the comparison with deterministic task work:

    work = 0
    work = 16
    work = 64

As task work increased, retry developed strong backpressure while inline
continued making progress by performing useful work on the producing thread.

Representative LDC results were:

    work=0
        retry   6.402 ns/task
        inline  6.918 ns/task

    work=16
        retry  41.576 ns/task
        inline 20.948 ns/task

    work=64
        retry 169.701 ns/task
        inline 81.360 ns/task

This established that retry-until-space is not a satisfactory general overflow
policy under sustained production and meaningful task work.

## P12c — Global locked spill

P12c added a deliberately simple reference spill structure:

- preallocated;
- FIFO;
- non-resizing;
- one mutex;
- batch worker consumption.

Overflow tasks remain schedulable and are not executed by the producer.

This preserved the semantic distinction between:

    producer

and:

    executor

better than execute-inline.

However, the global spill did not remove the scheduling/backpressure cost.

Representative LDC results:

    work=16
        retry   34.798 ns/task
        inline  16.787 ns/task
        spill   35.894 ns/task

    work=64
        retry  158.670 ns/task
        inline  80.503 ns/task
        spill  160.571 ns/task

The simple global spill therefore did not justify itself as the R0.1 policy.

## P12d — Normalized executor capacity

Earlier inline comparisons allowed:

    4 thieves + producer capable of inline execution

while retry/spill used:

    4 thieves

This could have given inline an effective fifth executor.

P12d therefore normalized the layouts:

    retry:
        4 thieves

    spill:
        4 thieves

    inline:
        3 thieves + producer

All policies therefore had at most:

    4 concurrent executors

The large inline advantage remained.

Representative LDC results:

    work=16
        retry   21.367 ns/task
        inline  20.155 ns/task
        spill   25.865 ns/task

    work=64
        retry  169.158 ns/task
        inline  57.095 ns/task
        spill  167.183 ns/task

Therefore the earlier inline advantage was not explained by an additional fifth
executor.

## P12e — Executor placement control

P12e removed queueing and overflow entirely and measured pure deterministic work
on the two executor layouts.

Compared:

    worker4:
        CPUs 0, 1, 3, 4

against:

    owner+3:
        CPUs 0, 1, 3 plus owner CPU 2

LDC:

    work=16
        worker4  = 7.977 ns/task
        owner+3  = 8.271 ns/task
        ratio    = 1.037x

    work=64
        worker4  = 38.600 ns/task
        owner+3  = 39.713 ns/task
        ratio    = 1.029x

The owner+3 layout is slightly slower for pure work.

Therefore CPU placement does not explain the inline advantage.

If anything, the normalized inline layout carries a small placement
disadvantage.

## P12f — Sharded spill

P12f tested whether the global spill result was primarily caused by one
contended mutex.

The reference spill was partitioned into:

    4 independent locked FIFO shards

The producer distributed overflow across shards.

Workers preferred one shard and scanned the remaining shards.

This deliberately changed only the spill contention structure; it did not
introduce a new lock-free queue algorithm.

LDC results:

    work=0
        retry    6.302 ns/task
        inline   6.987 ns/task
        global   9.436 ns/task
        sharded  9.277 ns/task

    work=16
        retry   21.308 ns/task
        inline  13.801 ns/task
        global  24.588 ns/task
        sharded 29.652 ns/task

    work=64
        retry   158.064 ns/task
        inline   80.352 ns/task
        global  152.372 ns/task
        sharded 156.936 ns/task

Simple sharding did not improve the spill architecture materially.

At work=16 it was worse than the global spill.

At work=64 both spill designs remained in approximately the same performance
class as retry and far behind execute-inline.

This does not prove that every possible injection queue will perform poorly.

It does establish that:

- one global mutex is not sufficient explanation for the spill result;
- simple lock sharding does not solve the problem;
- a more complex injection structure is not justified by current R0.1 evidence.

## Interpretation

The major problem with retry is not the cost of one failed push.

It is scheduler backpressure:

    producer reaches full local queue
        ->
    producer stops producing useful parallel work
        ->
    waits for consumers to create space

Execute-inline changes this to a work-first response:

    producer reaches full local queue
        ->
    producer executes useful work
        ->
    queue pressure falls indirectly
        ->
    system continues making progress

The effect becomes increasingly important when queued tasks contain meaningful
work.

## Selected R0.1 overflow policy

For ordinary tasks that are valid to execute on the current worker:

    execute inline when local bounded push fails

Conceptually:

    if (!local.tryPush(task))
        execute(task);

This policy belongs to the scheduler.

It does not belong inside the deque implementation.

## Local deque contract

The selected P08e local deque remains:

    bounded
    fixed-capacity
    non-resizing

A full result remains meaningful:

    tryPush(task) == false

The deque does not know or decide what happens next.

## Why no resize

P12 provides no evidence that local deque resizing is required.

Adding resizing would:

- complicate ownership;
- complicate publication;
- change memory-layout assumptions;
- introduce allocation into overflow handling;
- invalidate portions of the selected bounded-queue evidence.

The scheduler instead handles overflow explicitly.

## Why no global spill in R0.1

The tested global spill:

- preserved producer/executor separation;
- was correct;
- supported batch consumption;

but did not materially improve sustained-overflow throughput.

The tested sharded variant also failed to establish a performance case.

Therefore R0.1 does not add a shared spill/injection queue to the hot path.

## Scope of the inline decision

The selected policy is qualified for:

    ordinary runnable tasks

for which execution on the current worker is semantically valid.

P12 does not establish execute-inline as valid for every future task category.

Examples requiring later scheduler/API decisions may include:

- thread-affine tasks;
- UI-thread tasks;
- blocking-sensitive tasks;
- tasks requiring a particular executor;
- tasks whose execution context is externally constrained.

Such task categories may eventually require:

- explicit handoff;
- an injection queue;
- another executor;
- a specialized overflow path.

Those are not part of the R0.1 local-deque qualification.

## Fairness conclusion

The inline result was checked against two major fairness concerns.

### Executor count

P12d normalized all alternatives to four possible executors.

Inline retained its advantage.

### CPU placement

P12e showed that the owner+3 executor arrangement is slightly slower than the
four-worker arrangement for pure computation.

Therefore the observed inline advantage is not attributable to:

- a fifth executor;
- faster owner CPU placement.

The evidence supports a real scheduling/work-first effect.

## Rejected R0.1 policies

### Retry as default

Rejected.

Useful as a control, but sustained queue-full conditions create large
backpressure.

### Global locked spill

Rejected for R0.1.

Correct reference mechanism, but no demonstrated performance advantage.

### Sharded locked spill

Rejected for R0.1.

Reduced lock sharing does not produce a useful overall result.

### Local deque resize

Not pursued.

Contrary to the bounded local-deque architecture and unnecessary given the
selected scheduler policy.

## Deferred alternatives

Not ruled out permanently:

- specialized global injection queue;
- lock-free MPMC injection queue;
- sharded production-quality overflow queue;
- handoff to another worker;
- executor-specific overflow paths.

Current evidence does not justify adding those mechanisms to R0.1 before the
minimal scheduler has demonstrated a concrete requirement.

## P12 decision

    PASS

Selected R0.1 scheduler overflow direction:

    bounded local deque
    +
    execute-inline fallback for inline-eligible runnable tasks

The deque remains scheduler-policy independent.

## Next gate

Proceed to:

    P13 — Minimal scheduler harness

P13 should implement the smallest N-worker scheduler environment using:

- one selected P08e deque per worker;
- owner-local push/pop;
- stealing from other workers;
- batch stealing;
- the P12 execute-inline overflow policy;
- deterministic TaskRef payloads;
- exact accounting/checksums;
- startup and shutdown;
- scheduler observability.

Do not define the final public Executor or Task API as part of P13.
