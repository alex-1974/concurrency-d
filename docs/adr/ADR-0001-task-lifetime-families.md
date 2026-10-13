# ADR-0001 — Distinguish independent owned tasks from scope-bounded tasks

- **Status:** PROPOSED — research gate, **not yet an accepted public/API contract**
- **Date:** 2026-10-13
- **Issue:** [#17 — Scoped borrows, owned tasks and storage boundaries](https://github.com/alex-1974/concurrency-d/issues/17)
- **Related:** [#6 (M1)](https://github.com/alex-1974/concurrency-d/issues/6), [#20 (R0.5)](https://github.com/alex-1974/concurrency-d/issues/20), [#11 (M0 typed submission)](https://github.com/alex-1974/concurrency-d/issues/11)

## Context and evidence

The qualified internal transport is an eight-byte **non-owning** `TaskRef`, pointing at an address-stable `TaskHeader` and its specialized execution thunk. This is the accepted R0.2 representation, **not** a storage allocator or a lifetime token; see [R0.2 P06](https://github.com/alex-1974/concurrency-d/blob/research-integration/research/r0_2_task_representation/results/p06-task-representation-decision.md).

Current production M0 `source/concurrency/internal/owned_task.d` supports an *experimental*, package-internal owned executor. It retains each accepted GC-backed record under a strong `_retained` root until the record has returned from dispatch and can be safely reclaimed; typed `TaskHandle!R` and `ResultCell!R` live independently of the record. The submitting callable is `@system` because arbitrary borrowed/cross-thread captures are not statically certified. Shutdown and producer acceptance share a mutex. The separate R0.5 research implementation has additional recycling and diagnostics and must not be equated wholesale with M0.

The [post-admission R0.5 disposition](https://github.com/alex-1974/concurrency-d/blob/perf/r05-owned-task-pipeline/research/r0_5_task_storage/r05-post-admission-triage-and-next-gates-2026-10-13.md) rejects the existing two-stage admission reservation as a silent replacement. It also rejects treating a stack-resident scoped record as a faster equivalent of an independent owned task: the lifetimes differ.

The shared workspace `DESIGN_PRINCIPLES.md`, `DLANG_PRACTICES.md`, `QUALITY_GATES.md` and `GIT_GITHUB_WORKFLOW.md` govern this research. The repository `AGENTS.md` requires source/evidence review and explicit safety boundaries.

## Proposed separation — one transport, two lifetime families

### 1. Independent owned tasks

An accepted task's callable, captured referents and record remain valid even after the submission call returns and a `TaskHandle` is dropped. The executor owns **at least one strong GC retention path** for GC-managed record/capture storage, or an equivalently proved alternate ownership mechanism. A cancelled **request** does not discharge the outstanding execution/lifetime obligation.

- Admission **commits** a single work obligation only when publication succeeds.
- Closed/full rejection must not inadvertently transfer ownership or allocate the full per-task object graph after a known rejection gate (preserve current M0 behavior when replacing it).
- Dropping `TaskHandle` neither cancels the task nor unroots its record.
- A result becoming ready is **not** proof that dispatch and the last worker access have returned.
- Reclamation/reuse follows the final worker access, demonstrated in M0/R0.5 by a release `returned` marker and an acquire reaper.
- `closeAndJoin` drains all accepted work and is idempotent for external controller threads; self-join from an executor worker is not promised.

**Current recommendation:** `freshGc` stays the measured baseline for this family. Typed recycling is not a general throughput win in the existing R0.5 XPS corpus. This recommendation is not an assertion that future owned-task storage must always be GC-backed.

### 2. Scope-bounded tasks

A future `TaskScope` may allow a child task to borrow caller-owned memory **only under a strictly bounded joined lifetime**, with an explicit scope ownership and thread-safety discipline. A TaskRef into a scoped record is still borrowed; it does not convert the frame to owned storage.

- **Every** accepted child, including queued, claimed, stolen, executing, blocked, or already result-ready but not yet returned from dispatch, must reach a **quiescent post-dispatch** state before the borrowed referents, callable and record storage can be destroyed or moved.
- A scope cannot expose a detach path for borrowing children. Losing the last visible task handle must not end its join obligation.
- A task's requested cancellation is not completion. Scope unwind, failure propagation and nested joins must still drain admitted children before releasing parent borrows.
- A stack-backed record may not move after `TaskRef` publication. The compiler's struct copy/implicit-move behavior and destruction order demand independent proof; a generic container or callable copy must not silently relocate a published record.
- Allowing a borrowed *read* does not grant concurrent write authority, data-race freedom, uniqueness, or `immutable` storage. The scope/borrow API must document its synchronization and sharing constraints.
- If a scoped user callable can throw, join must still reach quiescence and then report failures by a deliberate policy (e.g. first exception + drain). An exception must never bypass the drain obligation.
- A destructor-only join is **not** accepted as sufficient without proofs for error paths, destructor execution, program shutdown and worker self-join. The design should begin with explicit `join` and a non-escaping lexical control flow; RAII is an additional safeguard after qualification.

`TaskScope`, `join`, task cancellation and their signatures are **concepts here, not implementation or frozen public API**. `TaskScope` is not yet claimed `@safe`.

## Shared record state / reclamation invariant

A useful conceptual sequence is:

```text
prepared (not published)
   → admitted / queued (root or scope borrow remains alive)
   → claimed / possibly stolen
   → executing
   → result recorded (may now wake handle waiters)
   → dispatch fully returned and worker no longer touches record
   → reclaimable / movable / destructible
```

Claiming a task removes an inbox slot but not the accepted execution obligation. `ResultCell.get()` may unblock before the worker's post-dispatch epilogue. No reclamation or stack exit may occur merely because a handle reports completion.

**Key lifetime predicate:** `all published TaskRefs to this storage are quiescent` must hold before destroying/moving any record or referent. The synchronization establishing it is family-specific; a raw `TaskRef` does not encode that predicate.

## D language and compiler boundary

- `scope`/DIP1000 can reject **some local escape forms** when a function is `@safe` and compiled with `-preview=dip1000`. The supported compiler versions for these experiments are **DMD 2.111.0** and **LDC 1.41.0**. Positive and whole-source negative fixtures must compile with the **same options and compile-only mode**.
- `return scope` deliberately allows a borrow to flow into the *caller's* lifetime; it does not mean detached execution can retain arbitrary callers' stack references.
- `scope` is not a transitive whole-object borrow checker; language checks do not prove synchronization, noninterference across threads, a TaskScope join protocol, GC root reachability, destructor execution or safe transport of arbitrary closures.
- `const`, `shared` and `immutable` have different contracts. Do not conflate read-only access, synchronized access, shared storage, and lifetime ownership.
- A general callable submitted through today's `@system` method does **not** become `@safe` by copying a `scope` annotation onto the submission parameter. Any future `@safe` overload needs a separately justified capture/ownership trait and run-time publication boundary.
- Keep `@trusted` restricted to narrowly justified thunk casts, native atomics and handoff primitives. Never turn an entire scope/executor `@trusted`.

The accompanying probes in `research/m1_task_lifetime/probes/` distinguish **compiler-enforced local escape rules** from these presently unproved concurrent guarantees. They do not establish a working TaskScope.

## Ownership and error table

| Event | Independent owned | Scope-bounded |
|---|---|---|
| Accepted publication | executor retains valid record / captures | enclosing scope retains records and all borrowed referents |
| Known full/closed rejection | no new execution obligation; current per-task allocation gate preserved | no child obligation and no escaping reference; provisional storage cleaned safely |
| Handle dropped | task still completes | scope still joins child |
| Result ready | handle may return; record not necessarily reclaimable | child still counts until worker quiescence |
| Cancellation requested | cooperative signal; no early destruction | signal; **scope still joins** |
| Unwind / callback exception | result/error observable; scheduler completion still runs | scope drains every child before errors propagate to parent |
| Scope/executor shutdown | executor joins all accepted tasks | scope exit cannot precede all child returns |
| Reuse/destruct | after last worker access and correct root accounting | after quiescence, while referents still alive |

## Consequences and rejected shortcuts

**Advantages:** a small type-erased scheduler remains usable for both families; owned and scoped storage policies can be specialized independently, so performance comparisons have truthful ownership semantics.

**Costs:** scoped execution requires a real join barrier/lifetime mechanism, can deadlock if child tasks block waiting for work that only the same exhausted pool can execute, and needs a separate cancellation/error protocol. These are design blockers, **not** reasons to synthesize a scope-friendly general `@safe` promise.

**Not accepted:** speculative GC-node stack substitution for detached owned tasks; `@trusted` around arbitrary user captures; returning from a scope when some worker still has a TaskRef; release of a record on result-ready; publishing before installing the strong owner; assuming `-preview=dip1000` proves safety of an arbitrary cross-thread callable; per-task recycling before the post-dispatch return marker.

## Qualification before acceptance

1. Run and inspect the **positive and negative** DMD 2.111.0 / LDC 1.41.0 probes, with `-preview=dip1000` explicitly enabled only for these standalone fixtures. A negative pass is a compile rejection with a matching positive control, **not** an unconditional claim of universal borrow protection.
2. Implement a **small internal TaskScope prototype** on a subsequent research slice, with intentional lexical join, no detach and pinned stable task addresses; do not prematurely expose it as public API.
3. Verify queued/claimed/executing/returned states under normal completion, exceptions, cancellation, shutdown and dropped handles. Add GC-visible capture, `void`/typed result, blocked worker, nested scope, move-only F/R and destructor-exactly-once tests where the API admits those cases.
4. Prove a safe scope-exit barrier with no lost publication or worker access after borrowed storage expires, including concurrent producer and close races and nested worker join limitations. Include negative consumer compile tests for forbidden escapes the chosen API can actually reject.
5. Only then compare **within** equivalent lifetime families using complete optimized LDC end-to-end throughput, tail latency, memory and CPU; keep controls uninstrumented and preserve original XPS evidence. No owned-versus-scoped speedup claim across different semantics.
6. Confirm independent consumer needs before API stabilization. #17 remains OPEN until the compiler, runtime and design evidence is complete.

## Research branching note

This issue's isolated `research/m1-task-lifetime-boundaries` branch was created from the exact `develop` M0 HEAD `7af4409a2e09a303dfbc6c54033d28c92eb67581`, **not** from the older `research-integration` snapshot. At inspection the latter was 137 commits ahead and 9 behind `develop` with unrelated R0 experiments. This is a documented research-topic exception to the normal parent preference, chosen to assess **current M0 semantics without dragging unrelated grandfathered R0 history or misleadingly patching PR #35**. No existing branch was reset, renamed or rebased. This proposal must not be merged into production as an accepted contract until its gates pass.


## P02 lexical-batch evidence update — 2026-10-13

A deliberately narrow, **synchronous** `runScopedBatch(scope Work[])` research kernel now provides pinned **private** task records and **unconditional join before function return** without giving callers access to individual TaskRefs. It reuses the existing eight-byte internal transport; unlike P01 it eliminates the *caller forgetting to invoke join* for this limited batch family. See [P02 detailed qualification](../../research/m1_task_lifetime/prototypes/p02_lexical_batch/README.md).

Compiler/runtime evidence at exact source commit `d0b6dfceb66398f93ecb4a60543216105ff681f0`: [GitHub Actions #38376599810](https://github.com/alex-1974/concurrency-d/actions/runs/38376599810), DMD 2.111.0 PASS and LDC 1.41.0 PASS (normal and `-O3` with assertions enabled). Includes distinct borrowed stack slots, GC-visible class capture under one forced collection, child `Exception` plus sibling drain, a destructor that runs after the join, bounded rejection before publication, 32 repeated eight-task calls, and disabled ordinary record-copy construction. These are **bounded tests, not a general proof**.

The experiment also showed that allowing a nested-worker call by wrapping a whole `@system` nested task runner in `@trusted` was **not justified** by the test; this wrapper and the misleading nested test were removed. Nested structured task execution stays OPEN.

**Interpretation:** keep P02 as a proof of a small synchronous batch regime, **not** a general public `TaskScope`, `@safe` cross-thread borrow contract, performance superiority, or a replacement for independent owned tasks. Specifically, `scope` does not prove callback captures are transitively thread-safe. Issue #17 remains OPEN; the original qualification checklist still applies to any dynamic scope design. ADR status remains PROPOSED.


## P03 bounded dynamic lexical-scoped admission — 2026-10-13

[P03 implementation, CI results, and safety boundaries](../../research/m1_task_lifetime/prototypes/p03_dynamic_lexical_scope/README.md) demonstrate that an *internal* `@system` builder can dynamically publish multiple tasks via a private portal into a two-worker, eight-inbox FIFO while retaining 24 distinct pinned records in the lexical caller frame. The builder's scope driver joins every accepted task in a `finally` before returning or propagating a builder `Exception`.

[CI run #38377974746](https://github.com/alex-1974/concurrency-d/actions/runs/38377974746) confirms P03 normal DMD 2.111.0 and LDC 1.41.0 correctness plus optimized `-O3` LDC correctness, *with asserts enabled*. It covers full-inbox rejection, dynamically interleaved completion and submission, no record-slot reuse, builder exception unwind, child Exception isolation, a GC-visible captured object, destructor-after-join ordering, and compile-time exclusion of direct `Portal.trySpawn` calls from `@safe` functions. This is not a production/benchmark gate.

**Substantive safety finding:** an outer lexical join is not sufficient to protect **every inner-block borrow**. A builder can capture the address of a shorter-lived local variable, publish an asynchronous callback, then leave that local's block before the outer `runScoped` finally joins. The producer callback/submission therefore stay `@system`. The `scope` annotation on the builder does not statically certify transitive closure captures or safe cross-thread mutable access. This excludes claiming a general `@safe` dynamic TaskScope from P03.

**Research decision:** KEEP bounded lexical dynamic join as a demonstrable internal mechanism; NO-GO for promoting the current portal as a public `@safe` scoped borrowing API. Keep Issue #17 OPEN and this ADR PROPOSED. Future API research must decide how to bind each borrowed referent to a verified quiescence point, not just the outer join, before adding nested worker spawn, concurrent producers, cancellation or native performance claims.


## P04 constrained `@safe` scalar-only task envelope — 2026-10-13

[P04 source, real consumer tests and detailed `@trusted` proof obligations](../../research/m1_task_lifetime/prototypes/p04_value_only/README.md) demonstrate a **deliberately narrower** execution family: accept a borrowed `scope const(int)[]` for **synchronous copying only** and a user operation of type `int function(int) @safe pure nothrow @nogc` (a function pointer, **not** a closure delegate). Publish internally pinned typed scalar records, join all workers, return only a by-value result.

[GitHub Actions #38378940463](https://github.com/alex-1974/concurrency-d/actions/runs/38378940463): source commit `d1a584980ae790881b9080b75900a1efb218899d`; **DMD 2.111.0 and LDC 1.41.0 PASS**, including optimized LDC `-O3` correctness. External source-compile controls prove a consumer explicitly annotated `@safe` can invoke P04, while a captured `delegate`, `@system` callback and nonpure callback are each rejected for their intended type reasons. The previously qualified nine DIP1000 fixtures and P01–P03 continue passing.

**Safety interpretation:** this is not a discovered borrow checker or general dynamic TaskScope. The typed, alias-free integer snapshot eliminates the particular arbitrary-closure capture escape that blocks P03, **by excluding that class of work entirely**. The P04 implementation uses a reviewable but still nontrivial private `@trusted` bridge into internal thread/queue operations; the compiler does not prove this bridge sound. Treat it as a research-only manually justified boundary pending independent review and broader failure/memory-model tests. Constrained value execution and explicit `@system` borrowed execution are separate legitimate families; do **not** promise that their APIs or performance are interchangeable.

**Issue #17 remains OPEN; ADR remains PROPOSED.** No TaskScope public API, generalized safety promise, or R0.5 storage decision is promoted by P04.


## P05 trust audit and bounded worker failure testing — 2026-10-13

The [P05 `@trusted` audit](../../research/m1_task_lifetime/prototypes/p05_trust_audit/README.md) revisits P04's **parallel** scalar execution proof rather than inventing another task family.

**Qualified improvement:** the empty and singleton input paths are now evaluated without any trusted worker lifecycle; preparation of scalar task records is compiler-checked `@safe`, and the parallel dispatcher now locally rejects invalid count/null operation before worker startup. Deterministic, test-only `Exception` injection after 0/1/3 accepted submissions verifies join-before-rethrow. Both remaining trust markers are individually recompiled as `@safe`; compiler errors confirm that the thread/condition/TaskRef and shared-header cast boundaries cannot simply be relabeled.

[CI #38382063661](https://github.com/alex-1974/concurrency-d/actions/runs/38382063661): DMD 2.111.0 and LDC 1.41.0 PASS, plus optimized LDC correctness for the ordinary `@safe` scalar consumer. Earlier P01–P03 and compile-negative gates remain PASS. The original P04 benchmark-free evidence stays preserved.

**Release decision: NO-GO for accepting a complete parallel `@safe` TaskScope contract.** The larger trusted function and the druntime worker lifecycle require an independent safety review, especially `Thread.start` partial-failure semantics, fatal worker `Error` and multiple-worker `Thread.join` exceptional cleanup. Passing a compiler challenge means a trust boundary is *necessary*, not that its manually asserted postconditions are sound. A one-line `@trusted` wrapper around an arbitrary `@system` scheduler would merely hide these same transitive obligations.

ADR remains PROPOSED; Issue #17 remains OPEN; no public API or production change is authorized by P05.


## P06 worker lifecycle — deferred error propagation is necessary but not sufficient (2026-10-13)

[P06 source-based analysis, documented failure and exact CI evidence](../../research/m1_task_lifetime/prototypes/p06_worker_lifecycle/README.md) qualified two important P04/P05 `@trusted` lifecycle edges:

- The default `Thread.join()` may rethrow a worker's unhandled `Throwable` before **other** native workers have joined. This contradicts using the plain join loop as an unconditional quiescence barrier. P06 uses `join(false)` to gather a worker failure, joins *every successfully started worker*, and only then propagates the failure.
- Successful task-accounting invariants (`accepted == completed` and empty pending queue) do **not** describe fatal worker termination. P06's first Error test failed under DMD/LDC because an Error aborting dispatch prevented normal completion accounting; that failure and a secondary mutex-cleanup abort were preserved in [original CI #38383612775](https://github.com/alex-1974/concurrency-d/actions/runs/38383612775). The corrected code distinguishes **quiescent failed** from **successfully executed**: both workers may die leaving two queued tasks unexecuted, but every worker is joined and the failure propagated without a success result.
- Injecting a failure before native worker start positions 0, 1 or 2 proves that **already confirmed** thread launches are drained on the simulated error path; it does **not** prove the outcome of an actual `Thread.start()` that throws after partially starting a thread.
- [Pinned CI #38384303420](https://github.com/alex-1974/concurrency-d/actions/runs/38384303420) PASS: DMD 2.111.0, LDC 1.41.0, and LDC `-O3` correctness with assertions enabled. P01–P05 remain passing.

**Binding release NO-GO:** `Thread.join(false)` can itself throw `ThreadException`. There is still no independently verified policy guaranteeing that the underlying native thread is quiescent when a join fails. Neither retrying nor forgetting that thread is safe by assumption; for stack-borrowed records, a failed native join cannot be treated as ordinary scope unwind. A production implementation must either (1) fail-stop before referents can expire, (2) provide a separately proven native join recovery model, or (3) adopt a storage/lifetime design with a genuinely safe retention/abandonment protocol. This is a design choice, **not** permission to turn current research into a public `@safe` TaskScope.

ADR remains PROPOSED, Issue #17 OPEN, Draft PR #38 DRAFT. No source outside this research topic was changed.


## P07 tagged druntime and native lifecycle failure analysis — 2026-10-13

The [P07 tagged-source audit and deliberately fail-stopping fault experiment](../../research/m1_task_lifetime/prototypes/p07_native_lifecycle/README.md) closes the distinction between **worker Throwable returned by a successful join** (P06 qualified) and **native lifecycle state that cannot be shown to have joined** (still unrecoverable under the current stack-borrow design).

Tagged DMD 2.111.0 [`osthread.d`](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/osthread.d) and LDC 1.41.0 [`osthread.d`](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/osthread.d) both use POSIX `pthread_join` and throw before clearing the native handle on failure. A `Thread` destructor may detach such a thread, which **does not** wait for its last access to stack TaskRefs. Both `start()` implementations check `pthread_attr_destroy` **after successful `pthread_create`**, hence a potential throw-after-launch window before the caller's `started++`. Critically, `onThreadError` in their tagged `threadbase.d` throws a preallocated **`ThreadError : Error`** despite `start()` being `nothrow`; native `join` failure instead throws `ThreadException : Exception`. See [DMD `threadbase.d`](https://github.com/dlang/dmd/blob/v2.111.0/druntime/src/core/thread/threadbase.d#L1164-L1181) and [LDC `threadbase.d`](https://github.com/ldc-developers/ldc/blob/v1.41.0/runtime/druntime/src/core/thread/threadbase.d#L1237-L1254). Startup guards must not catch only `Exception`.

A **research-only** `M1P07FailStop` version terminates the process via `abort()` if `start()` or a `join(false)` operation throws before proven quiescence. It has independently injected **simulated** post-native-launch `ThreadError` and native-join `ThreadException` hooks. [Pinned CI #38390697965](https://github.com/alex-1974/concurrency-d/actions/runs/38390697965) passes DMD 2.111.0, LDC 1.41.0, and LDC `-O3`: the normal `@safe` scalar consumer still passes with the research fallback enabled, while both isolated fault executables must emit a distinct marker and terminate by SIGABRT (134). **No actual invalid OS join operation was attempted** (POSIX invalid/self-join is not a portable, defined testing contract). On mainstream Linux `pthread_attr_destroy` generally succeeds, so the post-create branch is source-level evidence, not a measured practical failure rate.

**Engineering decision:**
- **NO-GO:** treating a native failed join, a detached thread, an unproven retry or a possibly successful-but-unreported launch as a normal recoverable scope exit while worker pointers may still reference caller-stack storage.
- **Possible but not accepted:** fail-stop on unprovable native lifecycle state. This protects against ordinary post-failure stack unwinding in a deliberately constrained Linux subprocess, at the cost of terminating the entire process. It is a **fallback experiment**, not a recommended default for high-availability consumers.
- **Preferred long-term distinction:** a parallel **owned-task family** can arrange retained executor-controlled records/captures, whereas a genuine borrowed `TaskScope` must achieve an independently proven join/lifetime boundary or explicitly adopt a documented fatal policy. Merely using GC does not retroactively make arbitrary borrowed stack referents owned.

Keep ADR-0001 **PROPOSED**, Issue #17 **OPEN**, Draft PR #38 **DRAFT**. No general parallel `@safe` TaskScope promotion or production merge follows from P07.


## P08 — Owned payloads versus borrowed stack records after uncertain shutdown (2026-10-13)

[P08 implementation, original source audit and failure/ownership matrix](../../research/m1_task_lifetime/prototypes/p08_owned_vs_borrowed/README.md) distinguish a **strongly rooted owned task record** from a **transitively owned payload/capture graph**. The real M0 OwnedTaskExecutor currently retains GC-allocated task nodes through RetainedTask[], but accepts arbitrary F via `trySubmit(F)(F callable) @system`; a closure with an external stack pointer remains borrowed even if the surrounding node lives on the heap. TaskHandle holds only a ResultCell and result readiness may precede worker quiescence.

A key code-level mismatch was confirmed in actual `source/concurrency/internal/owned_task.d`: on a caught `_pool.closeAndJoin()` failure, owned nodes are not explicitly cleared, but `_lifecycle = Lifecycle.stopped` is nevertheless set. **That state name is not a proof of successful native joins**, and task roots retained *within* an executor have not been shown to survive complete abandonment of the executor itself. The underlying SubmissionWorkerPool still uses default throwing `Thread.join()` during shutdown and after partial startup, subject to the P06/P07 failures. P08's static source checker is deliberately conservative and fails if these source assumptions change, demanding re-review.

The isolated research model retains an alias-free GC-owned scalar ValueNode while a worker is blocked, injects an **artificial** uncertain-join exception without invoking the native join, forces four GC collections with strong roots held, then releases the worker and obtains a **later genuinely successful `Thread.join(false)`** before freeing the owner root. Twenty-four independent cycles check ordinary reuse. [Exact-source CI #38396892324](https://github.com/alex-1974/concurrency-d/actions/runs/38396892324) passed DMD 2.111.0 and LDC 1.41.0, including LDC `-O3` with assertions. This **does not prove that an actual failed OS join is retryable** or that all real OwnedTaskExecutor captures are safely owned.

**P08 design direction (not yet accepted):** separate truly owned-transfer payloads, which must have a verified transitive ownership contract and a retained worker/executor graph, from explicitly borrowed lexical tasks that cannot safely unwind with an unproven join. A real owned executor needs distinct `shutdownUncertain` and `joinedStopped` states, preserving strong roots through uncertainty and specifying who owns them if handles/controllers are dropped. Do not equate `stopped`, `ResultCell.done`, an owned record header, GC, or an asynchronous result handle with proven native quiescence.

ADR remains PROPOSED, Issue #17 OPEN and Draft PR #38 DRAFT. No public `@safe` owned or borrowed TaskScope is promoted. Production code and unrelated R0.5 work stay unchanged.


## P09 — Conservative data-only transfer trait and independently rooted shutdown uncertainty (2026-10-13)

[P09 research, compiler fixtures, model and explicit GO/NO-GO table](../../research/m1_task_lifetime/prototypes/p09_transfer_contract/README.md) build on P08 by **separating copyable structural representation from general capture ownership**.

**Language-level evidence:** the compiler-checked `isInlineTransfer!T` is a *finite, conservative whitelist*: explicitly selected primitive types, fixed arrays recursively, and nonnested POD structs whose fields recursively qualify. It rejects pointers, slices, class references, delegate fields, function pointers, and non-POD structs; it makes no claim to classify all owned D object graphs. An explicitly `@safe` external consumer copies nested POD data with no borrowing, and **six external negative consumers** are rejected by the actual constrained `snapshotInline` overload for the intended types. Corrected DMD/LDC source uses the built-in `__traits(isPOD, T)` (not a nonexistent `std.traits.isPOD` import). [Compiler and initial model gate #38398861625](https://github.com/alex-1974/concurrency-d/actions/runs/38398861625) passed DMD 2.111.0, LDC 1.41.0 and optimized LDC `-O3`. The final explicit early-release rejection follow-up passed [#38399053729](https://github.com/alex-1974/concurrency-d/actions/runs/38399053729).

**Shutdown model evidence:** a separate research supervisor retains a GC-owned scalar work node independently of a dropped controller handle through `running → draining → shutdownUncertain`, four forced collections and an **active rejection of premature release**. Only a **genuinely successful later `Thread.join(false)`** permits transition to `joinedStopped` and release; 16 repeat leases exercise the same state requirements. An **injected** uncertain join does not prove actual failed native joins are recoverable or safely retryable, and the supervisor itself remains an explicit live owner.

**Design implication:** a true owned data/task family must separately prove (1) transitive payload ownership, (2) strong worker/executor retention through uncertainty, and (3) actual quiescence before reclamation. The current M0 generic `OwnedTaskExecutor.trySubmit(F) @system` provides none of those as an unrestricted public `@safe` guarantee. Borrowed caller-stack records retain their stricter join obligation. This is **not** a public transfer API, a generic `@safe TaskScope`, or a scheduler performance verdict.

**Disposition:** KEEP both bounded research mechanisms; NO-GO for promoting arbitrary owned/borrowed `@safe` execution until real M0 worker-lifecycle ownership and negative consumer contracts are qualified. ADR remains PROPOSED, Issue #17 OPEN, PR #38 DRAFT. No production code or unrelated branch modified.


## P10 — Typed P/R over the existing M0 TaskRef worker boundary (2026-10-13)

[P10 prototype, real consumer compile-negative gates, exact-source CI and structural cost comparison](../../research/m1_task_lifetime/prototypes/p10_typed_transport/README.md) bring P09's conservative `isInlineTransfer` constraint through the **actual production M0 `TaskHeader` / `TaskRef` / `dispatchTask` implementation** on native worker threads, without changing the production transport.

A `TypedRecord!(P,R)` has a header-first address-stable layout, by-value P input, by-value R output, and a template-specialized execute thunk invoking `R function(P) @safe pure nothrow @nogc` **without a captured delegate context**. An explicitly `@safe` consumer verifies POD-to-POD, nested fixed-array-POD to long, repeated eight-record batches, caller-mutation independence and zero/singleton paths. **Seven actual external compile-negative consumers** are rejected for pointers, pointer-valued struct fields, slices, class-valued result, delegates, @system operation or nonpure operation. The caller-facing API remains a **research-only, deliberately narrow** typed value family, not a general TaskScope or arbitrary F closure transfer.

[Exact-source CI #38401394397](https://github.com/alex-1974/concurrency-d/actions/runs/38401394397) passed DMD 2.111.0, LDC 1.41.0, and LDC `-O3` positive correctness with assertions. Recompiled-real-source challenges substituting `@safe` for the private `@trusted` lifecycle bridge and header cast **both correctly failed for safety reasons** under both compilers, confirming manual trust obligations remain.

**Architecture/cost limits:** this uses the unchanged eight-byte TaskRef transport but a **separate bounded two-thread mutex FIFO**, not the M0 `SubmissionWorkerPool`/work-stealing scheduler. The stack record avoids per-task OwnedNode/TaskHandle/ResultCell allocation but the pool starts and joins native threads per call; it differs from the long-lived owned executor in task lifetime, queue policy, retention, and result delivery. Both the header thunk and typed operation remain indirect function calls. There is **no fair benchmark or proven speedup**, and the P10 synchronous value-only semantics must not be compared against asynchronous owned work as though equivalent. The private trusted worker lifecycle includes a research **fail-stop** for uncertain native start/join, not accepted production ergonomics or total safety certification.

**Decision:** KEEP P10 as compiler-qualified proof that strongly restricted D compile-time typed P/R values can cross the **real M0 non-owning transport** without a new class-virtual abstraction, while retaining explicit manual lifetime gates. Do NOT approve a general public `@safe` parallel execution API, TaskScope, arbitrary capture ownership or performance claim from this slice. Continue ADR-0001 **PROPOSED**, issue #17 **OPEN**, Draft PR #38 **DRAFT**, `develop` and R0.5 PR #35 untouched.


## P11 — Typed records on actual M0 work stealing, with a deterministic steal path (2026-10-13)

[P11 research implementation, DUB consumer tests and qualification](../../research/m1_task_lifetime/prototypes/p11_real_pool/README.md) close the scheduling gap left by P10. A separate research DUB application imports the **unmodified** production `SubmissionWorkerPool`, `TaskRef` and actual `containers-d 0.2.0` WorkStealingDeque; it passes CT-specialized P/R inline records (P09 restricted types, no closure context) across the true ingress, local-owner and cross-worker work-stealing scheduler.

**Executed evidence:** P11 qualifies 256-task batches across one/two/four workers, bounded ingress, sixteen repeated scopes, POD→POD and nested-inline-POD→long calculations, exact accepted/completed/returned counters, and **integer result parity with the real M0 `OwnedTaskExecutor` using the same kernel and worker-count/ingress budget**. This is correctness parity only, not a fair async/owned-vs-synchronous/borrowed benchmark.

**Actual-steal proof:** a separate `@system` probe parks both workers in independent preparatory tasks, submits an eight-task batch, frees exactly one worker to drain that batch into its local deque and block on its head, then frees the second. The second worker processes **seven** tasks while the owner remains blocked, with the global ingress already drained. Those tasks are available only via the **actual unchanged M0 cross-worker stealing branch**. This proves branch execution in the tested controlled schedule without modifying production code; it does not prove scheduling fairness under arbitrary workloads.

**Compiler-contract evidence:** separate external DUB negative consumers verify that P11's deliberately `@system` entry is **rejected from `@safe`**, pointer-bearing P is rejected by P09's transfer trait, and an arbitrary delegate cannot replace the restricted function pointer. [CI #38405054192](https://github.com/alex-1974/concurrency-d/actions/runs/38405054192) passed these checks under DMD 2.111.0 and LDC 1.41.0. [CI #38405288768](https://github.com/alex-1974/concurrency-d/actions/runs/38405288768) also passed LDC's **research-only debug/assertions-on `-O3` configuration**, exercising the same typed, owned-parity, and actual-steal tests.

**Safety verdict:** the true M0 pool retains the start/join/native lifecycle weaknesses documented in P06–P09. P11 does not annotate the pool frontend `@safe` or put a broad `@trusted` blanket around it. The caller retains stack-pinned records until normal successful join; a **research-only process abort** if `closeAndJoin` throws avoids assuming a potentially failed native join is a recoverable scope exit. This intentionally extreme policy is not accepted public behavior and does not solve generic borrowed lifetimes, fatal callback Error, native start-after-launch, ownership of arbitrary capture graphs, or total native failure coverage.

**Performance verdict:** P11 used the real scheduler for both typed and OwnedTaskExecutor paths and computed identical kernels, but their ownership, worker lifetime, result handles, allocation and asynchronous semantics still differ. **NO measured speed, dispatch-cost or C++ parity claim** follows. A later matched-semantics benchmark can test codegen/dispatch or long-lived executor variants after the relevant safety model is fixed.

ADR remains **PROPOSED**; Issue #17 **OPEN**; Draft PR #38 **DRAFT**. No production, `develop`, or grandfathered R0.5 PR #35 changes.
