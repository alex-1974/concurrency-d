# R0.1 P13 — Minimal Scheduler Harness

## Status

    PASS

P13 integrates the selected P08e bounded work-stealing deque into the smallest
multi-worker scheduler environment needed to exercise production-neighbourhood
behaviour.

P13 deliberately does not define the final public Task, Executor, Scheduler,
cancellation, parking, fiber, or I/O API.

## Qualified scheduler model

The harness uses:

- 4 workers;
- one selected P08e deque per worker;
- exactly one owner per local deque;
- owner-local push;
- owner-local pop;
- batch stealing from other workers;
- deterministic TaskRef payloads;
- P12 execute-inline overflow handling;
- explicit startup synchronization;
- explicit completion/shutdown;
- exact task accounting;
- sum/XOR/work checksum validation.

The selected deque remains scheduler-policy independent.

## Required observability

P13 records:

- tasks executed;
- local pops;
- stolen task transfers;
- batch claims;
- stolen tasks per claim;
- failed steal attempts;
- owner busy retries;
- overflow-inline events;
- per-worker work distribution;
- wall time.

All observability requirements from the production qualification plan are
therefore represented.

## P13a — Single-producer scheduler stress

P13a deliberately places all initial production on worker 0.

This creates:

- strong local queue pressure;
- sustained overflow-inline execution;
- stealing by the remaining workers;
- batch transfer;
- owner-local requeue of stolen batches;
- repeated redistribution of work.

Configuration:

    workers  = 4
    capacity = 1024
    batch    = 8
    tasks    = 1,048,576
    work     = 16 rounds

### DMD

Representative result:

    executed       = 1,048,576
    localPops      = 461,141
    stolenTasks    = 865,045
    batchClaims    = 154,508
    stolen/claim   = 5.599
    failedSteals   = 112,468
    overflowInline = 432,927

    accounting/checksum PASS

### LDC

Representative result:

    executed       = 1,048,576
    localPops      = 443,177
    stolenTasks    = 786,386
    batchClaims    = 135,335
    stolen/claim   = 5.811
    failedSteals   = 127,509
    overflowInline = 470,064

    accounting/checksum PASS

All four workers executed tasks.

All local queues were empty at shutdown.

Exact task identity was preserved.

## Interpretation of stolenTasks

`stolenTasks` is transfer accounting, not unique task-execution accounting.

A stolen batch may be transferred into the thief's local deque.

A different worker may later steal some of those tasks again.

Therefore:

    stolenTasks

may exceed the number of tasks whose final execution occurred immediately after
their first steal.

This is expected scheduler behaviour and does not indicate duplicate execution.

Unique execution is validated separately by:

- total executed count;
- completed counter;
- value sum;
- value XOR;
- deterministic work checksum.

## P13b — Distributed production

P13b removes the single-producer assumption.

All four workers are producers.

Initial production is deliberately uneven:

    worker 0 = 3/8
    worker 1 = 3/8
    worker 2 = 1/8
    worker 3 = 1/8

For 1,048,576 tasks this is:

    worker 0 = 393,216
    worker 1 = 393,216
    worker 2 = 131,072
    worker 3 = 131,072

Workers 2 and 3 therefore complete their own production earlier and can begin
stealing from workers 0 and 1.

This tests a more realistic transition between:

    producer
        ->
    local executor
        ->
    thief

without changing deque ownership.

## P13b final qualification run

Configuration:

    workers  = 4
    capacity = 1024
    batch    = 8
    tasks    = 1,048,576
    work     = 16 rounds

### DMD

Per-worker production/execution:

    worker 0:
        produced       = 393,216
        executed       = 318,232
        local          = 5,146
        stolen         = 7,847
        claims         = 1,430
        failedSteals   = 989
        overflowInline = 311,656

    worker 1:
        produced       = 393,216
        executed       = 293,751
        local          = 439
        stolen         = 0
        claims         = 0
        failedSteals   = 5
        overflowInline = 293,312

    worker 2:
        produced       = 131,072
        executed       = 237,664
        local          = 90,135
        stolen         = 119,138
        claims         = 17,481
        failedSteals   = 3,751
        overflowInline = 130,048

    worker 3:
        produced       = 131,072
        executed       = 198,929
        local          = 61,157
        stolen         = 87,387
        claims         = 12,958
        failedSteals   = 3,179
        overflowInline = 124,814

Aggregate:

    elapsed           = 28,822,200 ns
    ns/task           = 27.487

    produced          = 1,048,576
    executed          = 1,048,576
    localPops         = 156,877
    stolenTasks       = 214,372
    batchClaims       = 31,869
    stolen/claim      = 6.727
    failedSteals      = 7,924
    overflowInline    = 859,830
    ownerBusyRetries  = 7,020

    accounting/checksum PASS

### LDC

Per-worker production/execution:

    worker 0:
        produced       = 393,216
        executed       = 303,789
        local          = 1,991
        stolen         = 2,262
        claims         = 382
        failedSteals   = 341
        overflowInline = 301,416

    worker 1:
        produced       = 393,216
        executed       = 294,362
        local          = 473
        stolen         = 4
        claims         = 1
        failedSteals   = 3
        overflowInline = 293,888

    worker 2:
        produced       = 131,072
        executed       = 183,243
        local          = 55,182
        stolen         = 78,524
        claims         = 11,509
        failedSteals   = 2,127
        overflowInline = 116,552

    worker 3:
        produced       = 131,072
        executed       = 267,182
        local          = 116,718
        stolen         = 145,902
        claims         = 20,416
        failedSteals   = 2,910
        overflowInline = 130,048

Aggregate:

    elapsed           = 27,479,700 ns
    ns/task           = 26.207

    produced          = 1,048,576
    executed          = 1,048,576
    localPops         = 174,364
    stolenTasks       = 226,692
    batchClaims       = 32,308
    stolen/claim      = 7.017
    failedSteals      = 5,381
    overflowInline    = 841,904
    ownerBusyRetries  = 2,530

    accounting/checksum PASS

## Owner busy retry qualification

The selected P08e deque uses a marked top state during batch stealing.

An owner pop that encounters an active batch marker:

1. restores its speculative bottom decrement;
2. records an owner-busy retry in research builds;
3. retries safely.

P13b observed:

    DMD = 7,020 owner busy retries
    LDC = 2,530 owner busy retries

Therefore the scheduler harness did not only exercise uncontended owner paths.

It produced real overlap between:

    owner pop
        and
    thief batch reservation

and completed with exact accounting and checksums.

This provides scheduler-level evidence for the selected marked-top coordination
mechanism.

## Overflow behaviour

P13b intentionally produces substantial overflow pressure.

Representative LDC:

    overflowInline = 841,904

This is approximately 80% of all submitted tasks.

That high ratio is not intended to represent a final production workload.

It demonstrates that:

- the P12 execute-inline policy remains correct under heavy pressure;
- bounded local queues do not require resize for scheduler progress;
- workers continue stealing and redistributing work while overflow is active.

Final overflow frequency under realistic application workloads remains a P14
and later scheduler-tuning question.

## Ownership contract

Each local deque continues to satisfy the P11 concurrency protocol:

    exactly one owner

for:

    tryPush
    pop

Other workers interact with that deque only through:

    stealBatch

No worker performs owner operations on another worker's deque.

Therefore P13 does not weaken the previously qualified deque ownership model.

## Correctness conclusion

Both P13 scheduler neighbourhoods satisfy:

    produced == expected tasks
    executed == expected tasks
    completed == expected tasks

and preserve:

    exact value sum
    exact value XOR
    exact deterministic work checksum

All worker queues are empty at shutdown.

No duplicate execution, task loss, stale task, or residual queued task was
observed.

## P13 decision

    PASS

The selected P08e deque is qualified for use inside a minimal multi-worker
scheduler harness.

P13 establishes that the combination:

    bounded local P08e deque
        +
    owner-local push/pop
        +
    batch stealing
        +
    P12 execute-inline overflow
        +
    multi-worker startup/shutdown

operates correctly under both:

    highly skewed single-producer pressure

and:

    distributed uneven production.

## What P13 does not establish

P13 does not yet define or qualify:

- the final public scheduler API;
- Task ownership/lifetime beyond the already qualified TaskRef model;
- cancellation;
- TaskGroup/Scope semantics;
- worker parking;
- blocking compensation;
- fibers;
- I/O integration;
- UI-thread executors;
- production injection queues;
- final victim-selection policy;
- final scheduler performance.

Those remain outside the minimal harness gate.

## Next gate

Proceed to:

    P14 — End-to-end scheduler qualification

P14 should move from scheduler-mechanism correctness to workload behaviour.

It should use representative synthetic scheduler workloads such as:

- recursive fork/join;
- fine-grained tasks;
- medium-grained tasks;
- coarse tasks;
- irregular task trees / load imbalance.

Measure at minimum:

- tasks/s;
- ns/task;
- scaling;
- work distribution;
- steals;
- batch utilization;
- failed steal pressure;
- overflow frequency;
- owner busy retries.

Performance comparisons must preserve equivalent work and equivalent scheduler
semantics.
