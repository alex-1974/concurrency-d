# M1 P34 — Owned submission cost anatomy

Date: 2026-10-15. Status: **source-backed research design**; no native timing result and no approved optimization.

Tracking: Issue #17, ADR-0001 PROPOSED, Draft PR #38. Previous evidence: [P33 native XPS](../p33_ownership_decomposition/evidence/xps-2026-10-15-results.md).

## Direct source audit

The original `source/concurrency/internal/owned_task.d` (Git blob `e74d6a73f956c562eab176e27687a47249f5815d`) implements `OwnedTaskExecutor.trySubmit(F)` under `synchronized (_mutex)`. A successful admission, after capacity checks, constructs exactly three distinct GC-managed objects in source: `ResultCell!R`, `TaskHandle!R`, `OwnedNode!(F,R)`. It appends a strong reference and a returned flag to `_retained`, then calls `_pool.trySubmit(node.reference())` while still inside the executor lock. Existing `_retained` storage may grow or be reallocated; `reapCompletedUnderLock()` is a conditional O(capacity) path if the retention budget fills. No source claim establishes an exact number of GC allocation events, byte count, or fixed per-call cost: class allocations and array growth are separate runtime mechanisms.

The research `GenerationalManager.publish(F)` in `p29_generational_owner.d` (Git blob `d19405f2ef0f8d7159978174c1a919ed6d66764f`) acquires the manager mutex to validate generation/phase and increment an active-operation count; calls the owned executor **outside** that manager mutex; reacquires it to decrement the count. Therefore two manager lock acquisitions per publish are visible in source but their cost is unknown. They are not one continuous manager-held critical section, and manager shutdown safety depends on the operation count.

The internal M0 inbox also has a separate mutex (Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`). Acquisition of this mutex occurs **inside** the executor's critical section on accepted work. Source structure establishes possible lock-order/nesting and serialization, but is not runtime evidence that one site dominates P31/P33 slowdown.

## P34 controlled experiment

1. Use a strict source-pinned *generated copy* of the exact owned-task implementation and of the P29 consumer. No edits to `source/` or public APIs. Preserve native worker join, strong owner roots, generational handle validation, operation counters and fail-stop behavior.
2. Partition `trySubmit` into entry-to-executor-lock, lock-acquisition wait, retention-capacity checks/reaping, `ResultCell` creation, `TaskHandle` creation, `OwnedNode` creation, retained-reference append, nested inbox submission, and lock exit. Instrument all **return paths**, including full/closed and post-append rejection, or classify the narrower measured domain explicitly. Do not turn a failed admission into a successful one.
3. Use bounded, per-producer (or other demonstrably race-free) telemetry, collected only after producer native join. Timer calls under the mutex alter the mechanism; pair untouched, null-probe and timed-probe binaries from precisely the same source and task work. Never subtract a guessed constant timer cost.
4. Record `GC.allocatedInCurrentThread` snapshots outside the inner per-task clocked section to estimate per-thread allocated bytes. Do not equate allocated bytes with reachable/live memory, retained-node count, or lifetime of a native TaskRef.
5. Keep P31's exact accepted count (8,192), four workers, ingress 128, retention 1,024 and producer counts 1/2/4, with fixed work variants `minimal`, `shared_atomic`, `sharded_atomic`; compare owner modes only within a work variant. Verify attempts, native completed count, and task-side counts/sums as originally.
6. Paired XPS LDC 1.41.0 release `-O3`, three warm-up and at least nine measured rounds, rotated full-process arms and source/compiler/CPU/governor metadata. DMD 2.111.0 and LDC 1.41.0 CI correctness required before native capture. All timing output remains diagnostic, not a performance gate.

## Do not conclude prematurely

- Three source-level `new` expressions do **not** prove exactly three GC allocator calls, constant GC cost, or one-to-one overhead.
- A `trySubmit` wrapper time is not pure allocator time or pure mutex wait.
- P32's borrowed-record direct scheduler omits owned record/result-handle semantics, so it is **not** a valid performance replacement for P31.
- A faster copy that removes P29 generation validation, active-operation fencing, explicit process GC root or join proof is an invalid comparison.
- P33 showed small thread-launch phases versus submission; it did not isolate per-task allocation.

**Current checkpoint:** pinned source-structure qualification is being added before any byte-level instrumentation. A runnable P34 timed/null control and native XPS result are still outstanding.
