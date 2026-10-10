# M0 submission backpressure — avoid allocation on known rejection

Status: small production promotion from the R0.5 storage research.
Tracking: [#11](https://github.com/alex-1974/concurrency-d/issues/11),
[#20](https://github.com/alex-1974/concurrency-d/issues/20).

## Observation

The previous `OwnedTaskExecutor.trySubmit` allocated a new GC-managed
ResultCell, TaskHandle and concrete OwnedNode before checking whether its
in-flight record budget or external ingress queue was full. A consumer
retrying `trySubmit` while the worker was blocked could generate garbage
without ever admitting a task.

## Narrow accepted change

`SubmissionWorkerPool.hasIngressCapacity` checks the mutex-owned inbox
occupancy. `OwnedTaskExecutor` makes this check while holding its existing
producer-side admission mutex. Other owned producers cannot publish in
the meantime; workers can **only remove** inbox entries. Therefore an
affirmative capacity check cannot turn into a full inbox on this path,
provided the internal pool continues to be accessible only through the
owned executor's admission protocol.

The executor first checks its lifecycle and reaps completed record roots
if its own retention budget is full. A known-full budget or ingress
returns `null` with **no new per-task GC objects**. Only an admissible
call proceeds to allocate the ResultCell, TaskHandle and OwnedNode.

All accepted tasks still have the same result/error semantics, stable
borrowed TaskRef address and deterministic draining shutdown.
This changes neither the 8-byte TaskRef nor the GC-fresh storage default.

## Test and performance caveat

A deterministic gate holds one worker busy and one inbox slot occupied;
300 repeated rejected `trySubmit` calls must return `null` without
increasing `GC.allocatedInCurrentThread` in the submitting thread.
After releasing the worker, both accepted tasks complete exactly once.

The change moves successful per-task GC allocations inside the admission
mutex. That trades known wasted allocations for potentially longer
producer lock hold during acceptance. It is not an unconditional
throughput speedup: optimize further only with native LDC end-to-end
evidence. A distinct, still-experimental typed-node cache is preserved
on [R0.5 PR #35](https://github.com/alex-1974/concurrency-d/pull/35).
