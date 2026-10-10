# R0.1 containers-d WorkStealingDeque adoption

Status: qualification in progress

## Purpose

Replace the retained internal P08e research candidate as the future
`concurrency-d` local-worker-queue dependency with the production
`containers-d v0.2.0` `WorkStealingDeque`.

The historical R0.1 probes and candidate remain immutable evidence. Adoption
uses new probes rather than rewriting the P09-P16 record.

## External dependency

Qualified target:

```text
containers-d 0.2.0
WorkStealingDeque!(T, Capacity)
```

The production container was derived independently from the accepted P08e
contract and has already qualified code-generation and native architecture
parity inside containers-d.

## Consumer gates

### A0 — TaskRef transport contract

Prove that the preferred non-owning consumer handle

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
}
```

is accepted and round-trips through owner pop, single steal and batch steal
from entirely `@safe @nogc nothrow` consumer code.

### A1 — distributed-production scheduler

Repeat the P13b semantic workload against the public containers-d API:

- four workers;
- distributed production;
- bounded local queues;
- batch stealing;
- P12 execute-inline overflow;
- exact task/checksum accounting.

Research-only queue snapshot and busy-retry hooks are intentionally absent.

### A2 — irregular end-to-end scheduler

Repeat the P14c deterministic irregular workload against the public
containers-d API:

- single and batch steal modes;
- four workers;
- identical graph and work functions;
- exact execution/spawn/checksum accounting;
- identical capacity and batch size;
- warmup and sampled timing.

The public deque intentionally exposes no stale `emptySnapshot` or research
retry counters. Adoption must not reintroduce those surfaces.

## Acceptance

Before the root package switches to containers-d:

1. A0 passes on DMD 2.111 and LDC 1.41;
2. A1 and A2 pass on both baseline compilers;
3. the same probes pass natively on Linux AArch64 / LDC 1.41;
4. A2 shows no material consumer-neighborhood performance regression on the
   four-physical-core AArch64 host;
5. only then add the root package dependency and internal queue binding.

The internal R0.1 implementation remains retained research evidence even after
consumer adoption.
