# R0.1 containers-d WorkStealingDeque consumer adoption

Status: PASS

## Decision

Adopt the production `containers-d 0.2.0` `WorkStealingDeque` as the
selected local-worker-queue primitive for future concurrency-d production
scheduler work.

The retained internal P08e implementation remains research evidence and is not
deleted or rewritten.

## Qualified dependency

```text
containers-d 0.2.0
```

Selected primitive:

```d
containers.WorkStealingDeque!(T, Capacity)
```

The concurrency-d binding is an alias only. No wrapper algorithm, storage,
memory-ordering layer or scheduler policy is introduced.

## A0 — TaskRef transport

Consumer representation:

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
}
```

Qualified operations from `@safe @nogc nothrow` consumer code:

- owner tryPush;
- owner pop;
- thief steal;
- thief stealBatch into caller-owned storage.

Result:

- DMD 2.111.0: PASS
- LDC 1.41.0: PASS
- native AArch64 / LDC 1.41.0: PASS

## A1 — distributed-production scheduler

P13b semantics were reproduced against the public containers-d API:

- four workers;
- distributed production;
- capacity 1024;
- batch size 8;
- P12 execute-inline fallback;
- exact task count;
- exact sum/xor/work checksum.

The public production deque intentionally provides no research-only
owner-busy counters or stale queue snapshots.

Result:

- DMD 2.111.0: PASS
- LDC 1.41.0: PASS
- native AArch64 / LDC 1.41.0: PASS

Representative hosted x86_64 results from the first green qualification:

- DMD: 26.538 ns/task
- LDC: 13.017 ns/task

These hosted x86 values are correctness/neighborhood observations, not
cross-machine performance claims.

## A2 — irregular end-to-end scheduler

P14c graph/work semantics were reproduced against containers-d:

- four workers;
- deterministic irregular graph;
- identical fanout/work functions;
- capacity 1024;
- batch size 8;
- single-steal and batch-steal modes;
- exact execution/spawn/sum/xor/work-checksum validation;
- two warmups and nine measured samples.

Baseline hosted x86_64:

### DMD 2.111.0

- single: 55.098 ns/task
- batch: 55.141 ns/task
- PASS

### LDC 1.41.0

- single: 24.398 ns/task
- batch: 24.385 ns/task
- PASS

These runner values are not compared with the XPS qualification host.

## Native AArch64 parity

Final root-dependency qualification:

- workflow: `R0.1 containers-d adoption`
- run: #4
- run id: `38065255493`
- commit: `218fcc48651fd8d73c58ae7791af81e94c8e20fd`
- architecture: aarch64
- CPU: ARM Neoverse-N2
- LDC: 1.41.0
- result: SUCCESS

A2 was executed in balanced order against the retained R0.1 P14c reference.

Final paired aggregate:

| Mode | R0.1 reference | containers-d consumer | Ratio |
|---|---:|---:|---:|
| single | 224.172 ns/task | 223.125 ns/task | 0.9953x |
| batch | 221.639 ns/task | 222.889 ns/task | 1.0056x |

Acceptance threshold:

```text
candidate/reference <= 1.10x
```

Result: PASS.

No material scheduler-neighborhood regression is visible.

## Root package qualification

The research adoption branch was then switched to the real package dependency:

```sdl
dependency "containers-d" version="0.2.0"
```

and a package-internal zero-cost alias was added for the selected local queue.

The final gate repeated:

- root `dub test`;
- root release build;
- A0;
- A1;
- A2;
- native AArch64 parity.

All jobs passed on DMD 2.111, LDC 1.41 and native AArch64/LDC 1.41.

## API differences intentionally accepted

The production containers-d surface does not expose the research-only:

- `emptySnapshot`;
- `sizeSnapshot`;
- owner-busy retry counters;
- forced-overlap hooks.

concurrency-d does not require these in production.

Scheduler termination and correctness are based on scheduler-owned exact
accounting, not stale concurrent snapshots.

## Ownership boundary

containers-d owns:

- queue storage;
- owner/thief synchronization;
- single steal;
- batch steal;
- bounded full detection;
- memory-ordering protocol;
- element transport rules.

concurrency-d owns:

- TaskRef / TaskRecord;
- task lifetime and reclamation;
- worker topology;
- victim selection;
- choice of single versus batch stealing;
- execute-inline overflow behavior;
- parking/wake;
- executor coordination;
- structured concurrency.

## Production promotion rule

The research branch must not be merged wholesale into develop.

Promote only the qualified production slice:

- containers-d dependency;
- internal alias binding;
- R0.1 roadmap decision;
- permanent root/compiler/native-AArch64 consumer gate.

Historical P08e code and P09-P16 evidence remain retained on the research
branches as independent evidence.

## Result

```text
CONTAINERS-D WORK-STEALING CONSUMER ADOPTION: PASS
```
