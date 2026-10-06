# Roadmap

## R0 — Scheduler foundations

Research and benchmark the primitive mechanisms before freezing a public API.

### R0.1 Work-stealing deque

Compare:

- Taskflow-style bounded Chase-Lev queue;
- cached-top variant;
- steal-one versus batch-steal;
- overflow/injection strategies.

### R0.2 Task representation

Compare:

- pointer-only task node;
- pointer + execute-function TaskRef;
- stack-resident structured tasks;
- pooled task nodes.

### R0.3 Worker scheduling

Compare:

- sticky/random victim selection;
- bounded searching-worker counts;
- continuation/direct-execution fast paths.

### R0.4 Parking and wake-up

Compare:

- condition-variable baseline;
- two-phase wait protocol;
- native platform primitives where justified.

Measure both wake latency and idle CPU use.

### R0.5 Allocation

Compare:

- GC allocation;
- stack-resident tasks;
- sharded task pools;
- slab/chunk allocation;
- GC-aware externally managed storage where required.

## R1 — Minimal execution core

Only after R0 evidence:

- Scheduler;
- WorkerPool;
- Task;
- TaskScope;
- cancellation;
- typed result/completion;
- clean shutdown.

## R2 — Consumers

Validate with independent real consumers before stabilizing the API.

Initial candidate consumer:

- dcanvas.

Other consumers are admitted only when they demonstrate genuine requirements.
