# M1 P08 — Owned versus borrowed task failure semantics

**Date:** 2026-10-13. **Status:** bounded research PASS. **No public API or general @safe guarantee.**
[Issue #17](https://github.com/alex-1974/concurrency-d/issues/17) · [Proposed ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md) · [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38) · [P07](../p07_native_lifecycle/README.md).

## Research question

A native join that fails does not establish thread quiescence. A worker may still hold a raw non-owning TaskRef. Does executor-owned task storage let us propagate the error and keep running, whereas a borrower of caller stack storage must fail-stop?

**Conditional answer:** owned value payloads can remain valid through a period of uncertain shutdown when both the record and its **complete reference graph** remain strongly reachable independently of the submitting caller frame. This does NOT itself make a failed native join retryable or ensure that the worker makes progress. Arbitrary captured pointers embedded in an owned heap object remain *borrowed*.

## Observations from actual repository code (static source audit)

P08's runner reads actual [owned_task.d](../../../../source/concurrency/internal/owned_task.d), [submission_pool.d](../../../../source/concurrency/internal/submission_pool.d) and the underlying [TaskRef transport](../../../../source/concurrency/internal/task_record.d) directly; it does **not** change production code or execute the production work-stealing pool.

- TaskRef transports one 8-byte non-owning pointer. The queue does not own the pointed-to record.
- OwnedTaskExecutor retains accepted GC-allocated OwnedNode objects in a RetainedTask array. A TaskHandle retains **only a ResultCell**, not the task node.
- OwnedTaskExecutor.trySubmit(F)(F callable) is **@system**. No validation proves that fields of arbitrary F own every referent; a copied struct containing a pointer to caller stack can still dangle.
- A ResultCell can become ready **before the worker returns** from executing its record. TaskHandle.get() is not a native quiescence barrier.
- In the current OwnedTaskExecutor.closeAndJoin(), after a caught pool shutdown Throwable, RetainedTask nodes are not explicitly cleared, but _shutdownFailure is stored and **Lifecycle.stopped is still set**. That state label does not prove every worker joined successfully. It also does not independently root the executor after all external references to it have been dropped.
- SubmissionWorkerPool.closeAndJoin() and startup cleanup call default Thread.join(), whose worker-Throwable rethrow can interrupt the rest of the join loop (P06). Native failure of even join(false) remains unresolved (P07).
- OwnedNode.execute attempts to catch a callback Throwable and publish it to the ResultCell. Ordinary user callback failure and extraordinary native lifecycle failure are different contracts.

The runner asserts these source patterns and fails on changes so that the issue is **re-audited**, not silently carried across a refactor. Static checks establish only what the current source says.

## Ownership/failure matrix

| Situation | Borrowed caller-stack records | Fully owned record plus closed value-only payload | Current real OwnedTaskExecutor |
|---|---|---|---|
| Ordinary execution | Caller maintains every referent until post-dispatch join | Can use executor/worker retention | Result-ready and worker-return are distinct |
| Result handle dropped | No change to caller borrow requirement | Root graph independent of handle | TaskHandle retains only result cell; executor retains node |
| Worker Error followed by successful joins | Return only after **all** workers have joined; unexecuted work is failure | Free retained payload after **actual** successful joins | Callback Throwable is caught by OwnedNode in most ordinary cases |
| Native join fails; worker state unknown | **NO-GO** for caller-stack unwind | Keep **entire** capture graph alive, maintain uncertain state; progress not guaranteed | Shutdown stores error and roots while executor reachable, yet marks stopped |
| Native start may throw after actual launch | Cannot assume worker never existed | Independent launch-time ownership is needed | _started increments only after start returns |
| Heap node contains pointer to expired caller local | Still unsafe borrowed data | **Not actually owned** | Generic F is accepted via @system only |
| Executor object abandoned after unknown shutdown | Stack borrow has no remaining lifetime guarantee | Only safe with an independently retained worker/owner graph | Survival after total controller abandonment not qualified |

**Design requirement:** separate true owned-transfer types from explicit borrowed tasks. Do not infer ownership from heap allocation, type name, GC, ready result, or a state named stopped.

## Isolated P08 execution experiment

[Source: m1_owned_uncertainty.d](concurrency/research/m1_owned_uncertainty.d). This is **not** a port of the real M0 scheduler. It isolates retention and avoids claiming parity with production work stealing.

1. A GC-allocated ValueNode contains only primitive int input and output fields: no caller pointer, borrowed delegate or external mutable reference.
2. A separate closure factory creates the worker's own frame, capturing its ValueNode, result receipt and synchronization Gate. The controller also retains ValueNode in a separate strong root.
3. The worker starts and blocks. A **synthetic exception**, issued without calling pthread_join, changes controller state from running to **uncertain**, *not* joined/stopped, while preserving the owned node reference.
4. The controller stays reachable and forces four GC collections while the worker is parked. Its strong node root remains present, and the receipt still shows no return.
5. The controller releases the worker and obtains a **real successful Thread.join(false)**; only then does it read result 42 and permit clearing the owner root.
6. An additional 24 independently constructed value-only workers finish with correct results and join correctly.

This proves one explicit rooted value-only configuration continues to operate after an **injected uncertainty** and until a **later successful native join**. It does **not** simulate an actual failing OS join, demonstrate safe retry, show progress under a permanently stuck worker, or prove transitive closure ownership in D.

## Exact evidence and reproduction

**Source/runner/CI commit:** 0111d3fc103366fefa71b14a3606e268c0474ac8.

[GitHub Actions #38396892324](https://github.com/alex-1974/concurrency-d/actions/runs/38396892324) — all jobs PASS:

- DMD 2.111.0, job **115294277314** — P08 static real-source audit and runtime PASS.
- LDC 1.41.0, job **115294277033** — normal and -O3 optimized correctness PASS with assertions enabled.
- Existing P01–P07 probes and the 4-positive/5-negative DIP1000 language fixtures remained passing.

From repository root:

    bash tools/research/m1_owned_vs_borrowed_prototype.sh dmd
    bash tools/research/m1_owned_vs_borrowed_prototype.sh ldc2

The runner uses a 20-second timeout per binary. No performance comparison can be drawn: the model starts an independent native thread per run, while real M0 uses a work-stealing pool.

## Decision: research KEEP; production NO-GO

**KEEP:** ownership needs to cover the **payload's full reference graph**, not merely TaskHeader storage. A controller state named **shutdownUncertain** should retain all owned records and captures until a successful native quiescence proof or an explicit fail-stop policy, rather than reporting successfully stopped after an unproven join. TaskHandle and worker ownership must be modeled separately.

**NO-GO:** promoting today's general owned submit API to @safe; using GC roots to legitimize borrowed pointers; claiming a real failed join is recoverable based on a simulated exception; treating the current Lifecycle.stopped-after-error as worker-quiescent; or returning from a borrowed scope when native join is unproven.

**Next bounded gate (P09):** qualify a typed transfer contract for primitive and genuinely indirection-free values using actual D compiler traits, with *external* positive and negative consumer probes; separately model the owned executor's shutdownUncertain state and define who retains the executor when result handles are dropped. Do not change production until the type/lifecycle contracts and an explicit failure policy are accepted.

Preserve ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT, develop and grandfathered R0.5 PR #35 unchanged.
