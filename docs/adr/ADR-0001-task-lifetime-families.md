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
