# R0.5 — Two-lock Admission and two-phase reservation feasibility (2026-10-13)

**Decision: DEFER implementation; continue as a separately scoped design hypothesis, not an accepted optimization or public API.** The current dual mutex protocol is semantically understandable and correct under the audited constraints, but the measured throughput decline at 4/8 producer concurrency does not prove the outer lock is the only root cause. A two-phase reservation could move ResultCell, TaskHandle and OwnedNode allocation outside the outer mutex **only by adding a reservation and shutdown protocol**. It would still need a serialized root-before-TaskRef commit and access to the inner inbox mutex. The added coordination may outweigh the saved critical-section allocation work.

## Source, engineering contract, and evidence provenance

- Repository: `alex-1974/concurrency-d`; active grandfathered `perf/r05-owned-task-pipeline` research branch. Baseline source and source-level audit were **`d3ee43f3527be5a7a914c77624630cb10dddb4b7`** and [the line-by-line ownership audit](r05-admission-lock-ownership-boundary-audit-2026-10-13.md). **No D scheduler, TaskRef, queue, result API, default policy or work-stealing code is changed here.**
- Repository root `AGENTS.md` inspected directly on the branch. Engineering contracts were read from the current **user-supplied canonical workspace document copies** `DESIGN_PRINCIPLES.md`, `DLANG_PRACTICES.md`, `GIT_GITHUB_WORKFLOW.md`, `QUALITY_GATES.md`, `RESEARCH.md`. **Repository snapshot discrepancy:** The GitHub tree for this branch does **not expose a `.workspace/` directory**, although the project expects workspace hardlinks in local worktrees. The supplied document copies were used to apply the shared contract; the precise state of the user's local hardlinks cannot be verified from GitHub. No attempt to invent missing repository paths or rewrite workspace documents was made.
- Current code: `source/concurrency/internal/owned_task.d`, `trySubmitImpl` around lines 434–674, `closeAndJoin` around lines 897–965, post-dispatch return/reclamation around 165–176 and 677–706; `source/concurrency/internal/submission_pool.d` `TaskInbox.trySubmit` around 252–349 and `TaskInbox.hasCapacity` around 352–362.
- Source-pinned native XPS [same-source Admission vs Worker diagnosis](results/xps-joint-admission-worker-cost-review-2026-10-13.md) at measured source `84fcb47b...`: escalating *instrumented* outer lock wait with 4/8 producers, and substantial **same-binary observer effect** (`joint_on/joint_off` median 0.7548×, 29/30 slower). Thus mutex elapsed wait is **not** a CPU nanosecond cost per Task or upper bound on a potential optimization. Earlier publication split recorded ~165ns root append vs ~2691ns composite inbox submission in an instrumented different-source campaign; this does **not** isolate `notify` or an inner lock and is not an additive performance breakdown.
- The existing research stays on Draft PR #35 / Issue #20, not automatically promoted to `develop`.

## Baseline synchronization and linearization

The outer `OwnedTaskExecutor._mutex` protects the lifecycle state, retention array and optional typed spare cache and serializes every admission decision with RUNNING→DRAINING. Within that held lock, the executor calls `TaskInbox.hasCapacity()` (inner mutex), builds ResultCell + TaskHandle + OwnedNode, appends a **strong GC root** and calls `TaskInbox.trySubmit()` (inner mutex again). The inbox performs closed/capacity validation, queue slot write, accepted and generation increments, and `NotificationPolicy.always` wakeup under the same inner mutex.

**The existing acceptance/closure outcome is serialized with the outer mutex**. The inbox publication is the actual transition that makes the borrowed one-word `TaskRef` visible to workers; the strong executor root must precede it. `closeAndJoin` transitions lifecycle under outer lock, releases it to close and join workers, then clears roots after join. `markReturned` is release-stored **after** the last worker access; reclaim acquires it. ResultCell readiness alone is not node-lifetime release.

The current full-ingress regression asserts **no extra per-task GC allocations** in 300 repeated blocked full-`trySubmit` attempts under the tested conditions. A pre-lock unconditional allocation would violate that proven property. There is **no validated single-operation hoist** of existing expensive work without a changed state protocol, as established by the preceding negative source audit.

## Candidate protocols compared

| Alternative | Main idea | Required new state | Preserves current contract without redesign? | Research decision |
|---|---|---|---|---|
| A. Current outer→inner locked admission | Check capacity before allocating; root then commit | None | Yes, established source/test baseline | **KEEP** |
| B. Speculative preallocate before lock | Build cell/node before knowing capacity or closed | None | **No**: producer GC allocations on rejected attempts; exception/return timing changes | **REJECT** for current contract |
| C. Unprotected precheck then allocate | Advisory `hasCapacity()` snapshot | None | **No**: stale full/closed and no slot reservation | **REJECT** |
| D. Two-phase reserve/construct/commit-or-cancel | Reserve **both** budgets, construct off-lock, commit rooted TaskRef | Pending tokens, slot/retention reservations, closure coordination | **Possible as a new protocol only**, not yet proven | **DEFER** |
| E. Publish outside outer after root append | Allow commit concurrent with close | Closure epoch/ticket, pending publication accounting, root registry | **No** without D-like redesign; root/close race | **DEFER** |

### Minimal state for alternative D

The state machine needs, at least:

- Lifecycle `RUNNING | DRAINING | STOPPED` and inbox `OPEN | CLOSED`.
- Separate counts of physically queued ingress entries `queued`, ingress slot reservations `reservedInbox`, durable rooted nodes `retained`, and retention reservations `reservedRetention`; typically one paired reservation per pending producer.
- Per-producer token `idle | reserved | built` (real implementation would need ownership identity, cancellation status, lifetime/epoch, and exception handling).
- The count of worker-claimed, still-executing tasks, post-dispatch returned nodes awaiting safe reclamation, accepted work and completed work.
- `closeAndJoin` controller state, condition signalling that pending reservations have reached commit/cancel; optionally ticket ordering if the submission ordering contract demands it.

**Required resource invariants:**

```text
queued + reservedInbox <= ingressCapacity
retained + reservedRetention <= maxRetained
accepted - completed == queued + executing
retained - returnedButStillRooted == queued + executing

A task must never be put into the shared inbox without durable GC
root ownership being established first.
No new reservation after RUNNING -> DRAINING.
Inbox cannot be closed while a pre-drain token can still commit.
STOPPED implies no pending tokens, no queued/executing tasks,
all accepted work completed, workers joined, roots cleared.
```

The last two count equalities are **abstract bookkeeping** in the model. They do not encode the real `ResultCell`, `TaskRef` pointer, compiler memory barriers or druntime GC root scanning.

### Candidate state transitions (NOT implementation pseudocode to copy blindly)

1. **reserve** under the outer (and necessary inner inbox) synchronization: require `RUNNING`; atomically reserve **both** budgets before any per-task result/node GC construction. A failure releases any partial reservation, returns bounded rejection with no task-object allocation, or throws for closed; no more than capacity/budget tokens can exist.
2. **construct** outside the outer admission lock: create ResultCell, TaskHandle and OwnedNode and maintain a **provisional producer-owned root** for the uncommitted record. No worker may yet see its TaskRef. If allocation or callable materialization fails, **cancel** the token on all unwind paths and do not publish.
3. **commit** with serialization against close: install the **durable executor root** before publishing the TaskRef, consume the reserved inbox slot, increment accepted and generation and perform the selected notification under the inbox mutex. A token reserved before DRAINING may finish; a token not yet reserved must fail. Any commit exception must have a defined cancellation path and must not leave accepted work without an obtainable handle.
4. **cancel** under synchronization releases **both** reservation counters, clears any provisional ownership and wakes a blocked closer. The precise exception policy must distinguish failure before and after commitment; after public publication a naive `catch` cannot safely undo executed work.
5. **close_begin** transitions RUNNING→DRAINING under the outer mutex. **It must not hold that mutex while awaiting a producer that still needs it for commit/cancel.** It waits for the pending reservation count to become zero while permitting already-reserved operations to commit/cancel.
6. **close_inbox** occurs only after pending tokens resolve. Then the existing worker claim/execute/after-return sequence drains accepted tasks. **close_join_clear_roots** occurs only after all accepted work finishes and all workers join; other concurrent closers await STOPPED.

**Linearizability is still unproved.** If a producer reserves before close but commits after the RUNNING→DRAINING transition, the acceptance operation may need to linearize at *reservation* while only the subsequent commit makes its TaskRef executable. A cancellation of a provisional reservation and a successful publication have different externally observable outcomes. If the library's exact admission ordering and close response time are contracted, this must be formally specified and checked before implementation. A simple commit-time linearization would appear to accept after DRAINING and conflicts with the current ordering. **This is an OPEN design blocker.**

**FIFO/fairness is also open.** Two producers may reserve in one order and commit in another because their construction time differs; a FIFO inbox then reflects commit order, not reservation order. Guaranteeing reservation-order commits requires tickets or staging, which may add head-of-line blocking and hold reserved capacity idle.

## Abstract bounded-state exploration: executable evidence

New standalone Python model `tools/research/r05_reservation_state_model.py` performs explicit-state BFS for a **hypothetical atomic reserve/construct/commit/cancel/claim/finish/reap/close protocol**. It assumes root registration and queue publication form **one abstract atomic commit** (thus builds in the property that a task is not published unrooted) and separately counts two capacity reservations. It deliberately does **not** run the D scheduler or claim to establish D's memory model.

Explored configurations for at most **3** committed tasks:

| Producers | Inbox capacity | Retention cap | Workers | Distinct reachable states | Transitions |
|---:|---:|---:|---:|---:|---:|
| 2 | 1 | 1 | 1 | 67 | 126 |
| 2 | 2 | 1 | 1 | 67 | 126 |
| 2 | 1 | 2 | 1 | 123 | 300 |
| 2 | 2 | 2 | 2 | 167 | 466 |
| 3 | 2 | 2 | 1 | 229 | 733 |
| 3 | 2 | 3 | 2 | 367 | 1360 |

Also exercised each combination with at most **4** commits (max observed 602 states / 2,318 transitions), testing all reachable state resource/ownership/count invariants and whether some path reaches STOPPED. This is **existential drain reachability**, NOT weak fairness, wait-freedom, bounded worst-case response time or proof of absence of deadlock in the eventual concrete locking code.

**Synthetic counterexamples deliberately rejected by the model:**

1. Two producers independently read one free slot then both enqueue without reserving: physical inbox overcapacity.
2. Controller closes the inbox at RUNNING→DRAINING while an earlier producer holds a built, pending token: that producer cannot commit; it can strand accepted/expected work.
3. Borrowed TaskRef published in the queue without durable root: GC lifetime invariant violation.

The model also allows an allocation/construction failure by `cancel` from either `reserved` or `built` before publication, and permits previously issued tokens to commit during DRAINING while new reservations are rejected.

**Qualified CI:** targeted [reservation state-model audit](https://github.com/alex-1974/concurrency-d/actions/runs/38365176191) PASS (Python syntax, normal bounded BFS, four-commit extension and invalid-shortcut assertions). This is a research-only Python correctness gate; there is **no new DMD/LDC compiler correctness result nor native performance result** for the reservation idea.

## Estimated cost tradeoff (qualitative, not nanosecond promises)

A simplified source cost ledger:

| Resource / serialization | Current A | Two-phase D |
|---|---|---|
| Outer mutex acquisition per accepted task | One, retained through construction and publication | At least **two**: reserve and commit/cancel |
| Inner inbox mutex entry | One capacity query + one commit under outer, separate worker claim traffic | Still required for actual slot reservation and for publication (could be additional synchronization) |
| ResultCell / TaskHandle / Node creation | Under outer | May run concurrently outside outer for reserved slots |
| Durable GC root append | Under outer, before enqueue | Still protected at commit, before enqueue |
| Pending task reservation bookkeeping | None | Two budgets/tokens, cancellation paths and close coordination |
| Full/full-ingress rejected attempt | No task-object GC construction | Still must reject before construction; reservations can cause additional logical admission pressure |
| Shutdown progress | One lifecycle transition + worker join | Must first await/drain pending reservations then inbox close and worker join |
| Submission ordering | Current outer serialized publication | Potential reservation/commit reordering unless separately constrained |
| Worker search, steal, notify safety | Current tested protocol | Must remain exactly equal; no relaxation allowed |

**Consequences:** Moving constructor/GC allocation outside the outer mutex might reduce outer critical-section hold, but root/publish and the nested inbox mutex still serialize. Two outer acquisitions and extra inner reservation/accounting can increase both CPU and contention; reserved slots can reduce effective ingress availability while producers build nodes, and closers can wait for stalled builders. The previous AdmissionProbe measured serious observer effect, so naive “outer wait 40µs minus allocation time” is **invalid** as a speedup estimate.

## Research decision and gates before any D prototype

**Current position: DEFER two-phase reservation D implementation** rather than modifying `owned_task.d` or `submission_pool.d` immediately. The abstract model is useful for defining proof obligations and excluding unsafe shortcuts; it has not resolved the **admission/close linearization**, GC root transfer/exception safety, ordering/fairness and true additional lock-cost questions. No new consumer requirement justifies changing the public API or weakening full-ingress rejection semantics.

To authorize a **separately scoped research-only prototype** later, require:
1. A coherent linearization narrative for reserve, acceptance, cancellation, and close, including concurrent closers, rejected/throwing submission, and task/handle observable ordering.
2. A concrete minimal D memory-ownership and GC-root transfer proof, accounting for provisional roots through construction and permanent root-before-worker-claim; release/acquire returned marker must remain intact.
3. An explicit **bounded** cancellation/exception protocol and a shutdown condition predicate that releases locks while waiting; no leaked capacity and no premature inbox close.
4. Decide whether current ordering/fairness guarantees permit commit-order FIFO rather than reservation-order FIFO. Do not silently alter observable task ordering.
5. Deterministic races including full ingress, retention cap, allocate-throws, multiple concurrently closing threads, worker sleeping at publication, forced GC while queued/executing and handles dropped/recycled. Include negative compile and DMD+LDC @safe/@system contract probes where applicable.
6. Only then run semantically fair **uninstrumented optimized LDC native Dell XPS** throughput/cpu/idle wake-tail/memory measurements at 1/4/8 producers versus current A. Probe-enabled timers are secondary explanation, not acceptance.

**KEEP now:** `freshGc`, `NotificationPolicy.always`, full foreign-victim coverage, GC-root-before-TaskRef visibility, bounded no-per-task-allocation rejection, and admission/close semantics. **No scheduler code, public API, `develop`, `main` or other repository changed.** Grandfathered Draft PR #35 and Issue #20 remain open.
