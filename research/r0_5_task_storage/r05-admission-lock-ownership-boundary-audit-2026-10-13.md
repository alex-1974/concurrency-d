# R0.5 — Admission mutex boundary and ownership/lifetime audit (2026-10-13)

**Research disposition: NO-GO for a simple single-operation hoist out of the outer Admission mutex.** In the existing R0.5 `OwnedTaskExecutor` semantics, the high-cost operations are deliberately conditional on successful bounded admission; root registration and inbox publication must be ordered and serialized with closure. No sufficiently independent, meaningful runtime operation was found that can be moved **before** the outer mutex without either allocating on rejected attempts, creating a reservation state machine, changing failure semantics or weakening the task lifetime guarantee. **No D implementation/ABI/queue/lock/test/CI code was altered by this audit.** This is a source analysis, not proof that no different future design could ever be correct/faster.

The audit responds to the [native Dell XPS same-source cost report](results/xps-joint-admission-worker-cost-review-2026-10-13.md) (`joint_on` outer mutex wait rises ~56→17,452→43,076 ns/attempt in minimal 1→4→8 producer cases; ~42→16,583→40,410 ns in compute). Enabling the AdmissionProbe slows the otherwise identical joint binary in **29/30** throughput pairs, median `joint_on/joint_off=0.7548×`; wall-clock mutex waits include descheduling and are **not CPU nanoseconds or a direct speedup estimate**. That evidence warrants auditing the critical section, not an automatic rewrite.

## Scope and verified source

- **Examined branch:** grandfathered `perf/r05-owned-task-pipeline`, source state `c57fc613d29a3f8fb7a24aa8972e71feb9e82720` at start of review. This documentation is the only intended branch modification; **`develop` remains at `7af4409a2e09a303dfbc6c54033d28c92eb67581`**. Research R0.5 `OwnedTaskExecutor` must not be equated with the separate production M0 executor or its public API.
- **Implementation:** `source/concurrency/internal/owned_task.d`: `trySubmitImpl` lines **434–674**, `reapCompletedUnderLock` lines **677–706**, `submit` and `closeAndJoin` lines **870–965**, `OwnedNode` lines **178–258**, `ResultCell` and `TaskHandle` lines **54–151**.
- **Pool and worker:** `source/concurrency/internal/submission_pool.d`: `TaskInbox.trySubmit` (~lines **252–349**), `hasCapacity` (~**352–362**), `takeBatch` (~**364–385**), `parkUnlessChanged` (~**462+**), `SubmissionWorkerPool.hasIngressCapacity` (~**699–703**), `closeAndJoin` (~**705–714**), `executeOne` (~**806–823**) and `workerLoop` (~**825+**).
- **TaskRef:** `source/concurrency/internal/task_record.d` defines the **one-word non-owning** header pointer and dispatch thunk, with explicit external node lifetime obligations.
- **Existing evidence:** [XPS publication split](results/xps-publication-split-review-2026-10-12.md) measured root append median ~**165ns/accepted Task** vs composite `_pool.trySubmit` ~**2,691ns/accepted Task** in the *instrumented, earlier-source* minimal workload; this does **not** isolate inbox mutex/notify CPU and does **not** give unbiased uninstrumented cost shares. More intrusive [inbox/notify profiling](results/xps-inbox-submit-review-2026-10-12.md) likewise is not a causal unprofiled time budget. The native waiter-aware notification and rotating-victim alternatives previously failed to show a stable advantage.
- **Workspace contract reviewed:** repository-root `AGENTS.md` and shared `DESIGN_PRINCIPLES.md`, `DLANG_PRACTICES.md`, `QUALITY_GATES.md`, `GIT_GITHUB_WORKFLOW.md`. Its transition section explicitly grandfathers the existing active research branch. Do not copy unrelated library implementation/CI policy.

## Actual critical-section ordering and task ownership

Current normal `trySubmitImpl!(F,false)` performs the same operations as timed `Observed=true` but without timing clocks, histogram writes or time-sampling side effects:

```text
Caller already has F callable by value, R=ReturnType!F known at compile time
  |
  +-- acquire OwnedTaskExecutor._mutex
       |
       +-- if lifecycle != RUNNING: THROW (no Task node/result allocations)
       +-- if retained budget full:
       |     reap completed only after acquire-loading post-dispatch flag
       |     if still full: return null (no Task node/result allocations)
       +-- call pool.hasIngressCapacity()
       |     under the separate TaskInbox._mutex:
       |     if capacity not currently available: return null, no allocation
       +-- allocate ResultCell!R (Mutex + Condition)
       +-- allocate TaskHandle!R wrapping that cell
       +-- allocate OwnedNode!(F,R) or EXACT-TYPE rearm from _spare
       +-- append RetainedTask(node, returnedFlag) to _retained
       |     [strong GC root COMMITTED]
       +-- pool.trySubmit(node.reference())
       |     under TaskInbox._mutex: closed/full predicate, enqueue TaskRef,
       |     accepted++/generation++, notify under NotificationPolicy.always
       +-- on unexpected full/closed:
       |     clear vacated _retained GC root slot AND logical length;
       |     optional typed spare rooting on recycle policy
       +-- on accepted: release OwnedTaskExecutor._mutex
  |
  +-- return already-allocated TaskHandle!R to caller
```

### Required happens-before and lifecycle properties

1. **Rejection without producer task-object GC allocations:** lifecycle, bounded retained count and ingress capacity are checked *before* creating `ResultCell`, `TaskHandle` or `OwnedNode`. The regression test at `owned_task.d` **1445–1487** checks repeated full-ingress `trySubmit` attempts cause no new **GC.allocatedInCurrentThread()** bytes for the observed producer. This is not a promise that evaluation/construction of the caller's argument `F callable` is allocation-free.
2. **Submission/close serialization:** the shared outer mutex protects `_lifecycle`, `_retained`, `_spare` and the decision to publish. `closeAndJoin` transitions RUNNING→DRAINING under this same mutex (lines 907–929), then **releases it before** invoking `_pool.closeAndJoin` and worker joins; other closers await STOPPED via the executor Condition. A submission that has passed the check retains the mutex until the publication decision. No accepted submission can slip between a completed lifecycle transition and the inbox close.
3. **Two lock scopes, no observed inverse order:** the path takes `OwnedTaskExecutor._mutex` **outer**, then `TaskInbox._mutex` **inner** for `hasCapacity` and `trySubmit`. Workers hold the inbox mutex for `takeBatch`, completion accounting and generation-safe waiting, then operate deques outside that mutex. `markReturned` only sets an atomic post-dispatch completion flag; it does not take the outer mutex. Shutdown deliberately avoids holding outer during the worker join. This source-level graph finds no visible `inbox→outer` nested acquisition in the audited worker path, but is not a whole-process proof against arbitrary user callback deadlocks.
4. **Root-before-publish:** `_retained ~= RetainedTask(node,node.returnedFlag())` precedes the one-word borrowed `TaskRef` entering the inbox and foreign worker queues. `TaskRef` carries **no owner/root**. Merely leaving `node` on a temporary submitting producer stack would not constitute a durable root across the producer returning and the worker using the borrowed pointer.
5. **Completion and reclamation, distinct from result-ready:** `OwnedNode.execute` completes `ResultCell` (or records a caught Throwable), but the worker's `SubmissionWorkerPool.executeOne` calls `_inbox.completeOne()` and only then `_afterExecution(task)`, which is `markReturned`. `markReturned` uses **release** atomic store, and `reapCompletedUnderLock` uses **acquire** load before clearing/swapping a root. This prevents treating `TaskHandle.get()` being ready as proof that the worker no longer references its node.
6. **Typed reuse is additionally constrained:** `_spare` is protected by outer mutex and a cached node is reusable only when its concrete `OwnedNode!(F,R)` type matches; the previous result handle retains its **distinct** result cell. Ordinary default `freshGc` does not rearm typed nodes. Retained/spare arrays clear vacated backing slots to prevent stale GC roots. A reaper/typed-lookup hoist requires distinct synchronization/happens-before reasoning, not just an index scan outside mutex.
7. **Safety scope:** arbitrary callable captures use `@system` submission. Borrowed references, move-only destruction, exception-safe partially initialized nodes and GC/thread-escape behavior do **not** become general `@safe` guarantees merely because these internal unit and benchmark cases pass.

## Operation movement decision matrix

| Current operation (inside outer lock) | Can we hoist it as-is *before* outer lock? | Precise obstacle or classification |
|---|---|---|
| `if (_lifecycle != running)` | **NO** | A preliminary unlocked read is a data race; even a synchronized snapshot is stale before close. Final check must serialize with close; post-close rejection must be checked before allocating task objects. |
| `_retained.length` / budget gate / `reapCompletedUnderLock()` | **NO** | Mutates retained roots and optionally spare state under its mutex; post-dispatch acquire flag is necessary. Reclamation from another thread needs a new ownership protocol. |
| `_pool.hasIngressCapacity()` as **decisive** gate | **NO** | Lock-only standalone check is *advisory*; capacity can change and outer shutdown can transition. An early negative can spuriously reject despite freeing capacity or report null when post-close submissions must throw. Positive capacity cannot reserve a slot outside outer serialization. A speculative early read plus required final under-lock recheck is extra traffic, not demonstrated removal of work. |
| `new ResultCell!R()` (including ResultCell mutex/Condition) | **NO under current contract** | Allocating before capacity/lifecycle check violates no-throwaway-GC-allocation full rejection regression; may allocate for submissions subsequently closed. |
| `new TaskHandle!R(cell)` | **NO** | Same precheck objection. Moving it **after successful publication** instead is also not behavior-preserving: if construction/allocation throws after enqueue, the Task is accepted and may execute, but the caller has no handle for that accepted work. Currently handle exists before the acceptance linearization. |
| `_spare` exact-type search / `node.rearm` | **NO** | Mutable shared typed cache, post-return marker and record layout cannot be independently accessed/rearmed; research-only policy and counterexamples of handles outliving reused concrete nodes. |
| `new OwnedNode!(F,R)(callable,cell)` | **NO under current contract** | Depends on already-created cell; pre-admission allocation loses bounded rejection-before-allocation, and pre-publish callable materialization/GC anchoring requires lifetime proof. |
| `_retained ~= RetainedTask(...)` | **NO** | Durable strong root must be registered under protected mutable array state **before** borrowed-pointer publication. An external alternative GC root registry would constitute a redesigned protocol. |
| `_pool.trySubmit(node.reference())` | **NO** | Executes the inbox mutex-protected publication, generation and notification; must be ordered with root registration and close/acceptance. Removing the outer lock while publishing creates a new reserve/commit/shutdown race. |
| Success handle return | **ALREADY OUTSIDE** | Returns after leaving synchronized block; no meaningful hot-path move remains. |
| Type `ReturnType!F`, static node thunk layout | **ALREADY COMPILE-TIME** | No expensive runtime computation exists to move. |

**Net finding: zero currently qualified *single-operation* hoists** meeting all constraints. This conclusion does **not** prove that the current doubly locked design is optimal. It establishes that a simple line move is not a safe standalone optimization.

## Can we safely shorten the outer critical section with a larger new protocol?

**In principle, yes only after defining a new explicit reservation/commit/cancel model**, but this is **new architecture**, not a micro-optimization:

1. Under outer lock, atomically reserve **one** retention obligation and **one** future inbox capacity unit, identify lifecycle epoch and ensure shutdown cannot join/free the reserved work prematurely.
2. Release outer lock, allocate cell/handle/node and hold a producer-side GC root, with *exception-safe cancellation* for allocation failure, user callable construction/throw and shutdown racing a half-built reservation.
3. Reacquire synchronization to install a **durable** root, commit to inbox, ensure FIFO/worker wake-generation correctness and release/transfer reservation counts.
4. `closeAndJoin` must correctly wait for/cancel outstanding reservations, while workers can drain and notify with no lost wakeups. A reservation must not leave permanently unavailable capacity or allow worker access to unrooted storage.
5. Preserve the external exactly-once acceptance, handle observability on success, exception/backpressure contract and meaningful memory bound on uncommitted per-producer allocations. D's `@system` callable capture limitations still apply.

This is **DEFER**, not a candidate selected for implementation. The prior instrumented publication split shows GC-root append ~165ns versus inner inbox submission ~2,691ns; even eliminating *all* root append work would not address most of that **instrumented** publish bracket. The nested inbox mutex plus `Condition.notify` may remain relevant, but earlier waiter-aware notify A/B did not yield a stable benefit and the latest admission probes have a very large observer effect. No proposed speedup has been measured.

## Existing regression evidence and required gates for a future candidate

Source-level regression tests already present:
- `owned_task.d` **1140–1150**: post-close submission rejects.
- **1152–1197**: blocked worker, retention cap and *result-ready versus post-dispatch returned* separation.
- **1199–1232**: thousands of accepted tasks through small retained budget while many handles are dropped.
- **1234–1310**: three concurrent shutdown callers, pending worker, idempotent close and task results/errors after join.
- **1312–1340**: concurrent producer submissions racing shutdown, accepted/completed count agreement.
- **1357–1425**: typed reuse with distinct original result handle, heterogenous callable shape and `GC.collect()` after joining.
- **1427–1487**: zero-reuse GC policy and producer-thread no-GC-allocation on 300 full-ingress rejections for both storage policies.
- `submission_pool.d` **1133+**: inbox closed/full paths, worker claim/accounting, generation/predicate and shared completion contracts.
- XPS native mixed-type full-victim benchmark under four workers, multiple producers and GC version; [joint XPS cost report](results/xps-joint-admission-worker-cost-review-2026-10-13.md) validates task counts and same-binary probe observer effect, **not all unexercised lifetime corner cases**.

Future intervention acceptance **MUST** add explicit exact-boundary tests beyond this audit, before interpreting LDC throughput:
- Deterministic blocked worker + full ingress + concurrent producers; prove **zero result/node allocations on rejection**, including when a new reservation or construction fails.
- Concurrent `trySubmit`, `reclaimCompleted` and two or more `closeAndJoin` callers; no lost accepted work, deadlock or post-close task publication.
- Injected allocation/construction exceptions at **each** proposed reservation/commit phase; accepted work always has a valid handle, rejected work never executes, reservations cannot leak.
- Strong-GC-root proof under repeated forced `GC.collect()` **while** workers hold queued and executing borrowed TaskRefs; validate result cell independence after drop/reuse.
- Release/acquire visibility for the returned marker and atomic exactly-once worker completion; task handles may finish before node reclamation, not vice versa.
- Original full-victim foreign queue coverage, idle wake/tail latency, generation-safe work-before-park progress and bounded close/drain.
- Same-source **uninstrumented** release baseline versus candidate with DMD 2.111 correctness, LDC 1.41 optimized **native XPS** throughput under 1/4/8 producers and different arrival/batch/retention/workloads. Include DMD/LDC x86 and native ARM64 correctness plus task contract and negative compile tests wherever applicable.

No new test has been added or executed as a result of this **source-only audit**; existing historical CI and native evidence remain the evidence cited above.

## Recommendation

**KEEP** current admission/closure serialization, bounded rejection before per-task allocation, ResultCell/TaskHandle-before-publication, strong GC-root-before-TaskRef-publication, typed returned acquire/release, full victim search and `NotificationPolicy.always`. **DEFER** opportunistic early allocation, incomplete capacity snapshots, async handoff after outer unlock, speculative recycling, lock-free inbox and condition-notification suppression.

If performance research continues, focus on a **separate narrowly scoped mechanism / design tradeoff** (e.g. explicitly model a two-phase reservation and its failure/close states *on paper first*, or investigate inbox mutex/wake cost under low-observer uninstrumented controls). Do not promise the present contract can be optimized by a trivial mutex boundary move. Record this *negative* result and do not expand grandfathered Draft PR #35 into an unbounded redesign. Issue #20 remains open; no writes to `develop` or other workspace repositories.
