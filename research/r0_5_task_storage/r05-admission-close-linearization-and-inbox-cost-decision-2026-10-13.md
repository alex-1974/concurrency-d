# R0.5 — Admission/close linearization versus inbox notification costs (2026-10-13)

**Research outcome: NO-GO for the proposed two-phase reservation as a drop-in replacement under the currently observed Admission contract; KEEP existing outer→inner locking and NotificationPolicy.always.** This follows from two explicit semantic conflicts, not a newly measured speedup/regression:

1. Reserving before `closeAndJoin()` and **publishing after** the RUNNING→DRAINING transition does not provide a simple single commit/close linearization compatible with the existing `acceptedCount()` observation and rejection semantics.
2. Solving that by **revoking** an unfinished reservation on close can reject a producer *after its ResultCell/Handle/Node have already been allocated*, unlike the current pre-allocation close/full rejection paths. New temporary allocation during a rejected close race is **not yet accepted as an equivalent contract**.

The [original two-phase feasibility report](r05-two-stage-admission-reservation-feasibility-2026-10-13.md) and its `r05_reservation_state_model.py` remain valuable **abstract capacity/root reachability evidence**, but its atomic root+enqueue assumption and existential route to STOPPED did **not** establish linearizability, real-time query consistency, or preservation of the allocation-on-rejection boundary. This additional audit **narrows** that earlier positive result; it does not supersede or rewrite the historical original.

## Scope and engineering baseline

- Repo `alex-1974/concurrency-d`, grandfathered `perf/r05-owned-task-pipeline` research branch; audit base report commit **`817dc1274f6960791582439e2d247c25c1d3f690`**. Root `AGENTS.md` and user-provided shared workspace engineering docs reviewed. The GitHub repository snapshot has **no `.workspace/` directory**, whereas the local workspace contract expects workspace-managed links; no write to or guess about the actual local workspace was made.
- Production `develop` remains **`7af4409a2e09a303dfbc6c54033d28c92eb67581`** (M0-related implementation is distinct). No change to `source/concurrency/internal/owned_task.d`, `source/concurrency/internal/submission_pool.d`, public API, TaskRef, locks, queue, GC roots, notification or victim traversal.
- Source `owned_task.d`:
  `trySubmitImpl` (approx. lines 434–674) acquires outer mutex, checks lifecycle and budgets **before** constructing result and node, installs durable `_retained` root and calls `TaskInbox.trySubmit`; `closeAndJoin` (approx. 897–965) transitions RUNNING→DRAINING under **same** mutex before unlocked worker joins.
  `acceptedCount()` (near 981) delegates to `_pool.acceptedCount()` with an inbox-mutex-protected read. It exposes *committed inbox publication count*, **not** reservations (this is an existing research diagnostic, not a newly frozen public API).
  `TaskInbox.trySubmit` (submission_pool.d 252–349) under the inner mutex writes a borrowed TaskRef slot, increments `_accepted` and generation, and performs `_changed.notify()` under always policy. The accepted work is already strongly rooted.
- Source-level existing rejection path creates no ResultCell, Handle or OwnedNode after discovering closed/full. `owned_task.d` has an explicit producer-thread `GC.allocatedInCurrentThread()` regression for **repeated full inbox** (`freshGc` and typed policy); the same property on a racing close was established **by code inspection**, not by a dedicated allocation-measuring close test. Rejected attempts may still perform retention reaping (not a universal zero-GC-allocation guarantee).

## Close/admission histories that the original model left unresolved

We distinguish **physical commit**, **public acceptance**, **observation** and **shutdown cut**. These cannot be treated as the same event for a new two-phase design.

### History H1: late commit conflicts with fixed COMMIT as acceptance point

```text
P: trySubmit.invoke → reserve → off-lock construct -------- commit → OK
C:                             close.invoke → DRAINING ----- join → return
```

If RUNNING→DRAINING is the fixed close linearization point, allowing this `commit` to accept after the cut cannot simultaneously treat that **later physical commit** as the fixed acceptance linearization point and maintain a sequential specification forbidding successful submissions after close. The calls overlap, so some **different earlier conditional** linearization might exist; the history is not a proof that *all conceivable* protocols are non-linearizable. It invalidates the *naive chosen pair of fixed points*.

### History H2: a reservation is not necessarily irrevocable acceptance

```text
P: trySubmit.invoke → reserve → construct throws → failure response
```

Counting `reserve` itself as an irrevocable successful admission would create an accepted obligation with no callable, valid TaskHandle or publication. A token may instead be a **revocable permit**. But in that case `reserve` is not a simple unconditionally valid acceptance linearization point.

### History H3: real acceptedCount observation distinguishes permit from acceptance

```text
P: invoke → reserve ---- construct ---- commit accepted++ → return OK
O:                    acceptedCount() == 0
```

The source's diagnostic `acceptedCount()` returns `_pool._accepted` and does not include reserved permits. Treating `reserve` as a **fixed** successful acceptance point while the count still returns zero violates this *particular existing counter semantics*. It would require a redesigned definition/accounting of `acceptedCount()`, or a different more complicated linearization narrative, not a silent code motion. The counter is not claimed here as a frozen general-purpose public API guarantee.

### History H4: revocation on close avoids late acceptance but rejects built work

A constrained alternative revokes all **not-yet-committed** permits at the same close cut:

```text
P: reserve → construct ResultCell/Handle/Node ---- sees revoked → CLOSED
C:                               RUNNING→DRAINING → await token ACK
```

Physical publication never happens after DRAINING, and `acceptedCount()` still reflects only successfully committed Tasks. But the producer has already allocated a concrete Task that later fails to submit due to close. Today a producer that reaches closed checking *before* its allocation never builds that Task. This is a **contract and resource-behavior change**; it must not be dismissed as just a different placement of the outer mutex. A builder blocked between reserve and cancellation can also prolong `closeAndJoin()`.

Note: revocation is only an **abstract close-cut operation** in the model. A real D program cannot safely mutate an active producer's private construction frame without a separate synchronized revocation flag/epoch and owner acknowledgement. `closeAndJoin()` must not wait with the Admission mutex locked if the producer must acquire it to acknowledge/cancel.

### History H5: delaying the close linearization is not a free escape

One might postpone the abstract close point until all pre-close reservations finish, permitting their late commits. Then a different producer that invokes `trySubmit` during the draining interval and promptly throws `closed` would return **before** that proposed late close point. Such an early rejection cannot have a linearization point *after* a not-yet-occurred close while staying within its invocation/response interval, under the same simple sequential contract. Fixing that requires delaying rejection, an additional state rule, or changing the contract. Again, this excludes the **naive fixed-point story**, not all possible future concurrency specifications.

### H6: reservation order and inbox order differ

```text
P0: reserve(0) -------- slow construction ----- commit(0)
P1:      reserve(1) → quick construction → commit(1)
```

A FIFO inbox orders these tasks by **commit**, not reservation. The current code serializes entire accepted publications under the outer mutex. Whether an ordering between overlapping producer calls is itself part of the user contract requires separate API analysis; **do not introduce a new FIFO promise in order to claim a violation**, but do not silently treat reservation order as current enqueue order either. Enforcing reservation-order publication would require tickets/staging and may add head-of-line blocking.

## Extended executable bounded-state experiment

New research-only [`tools/research/r05_admission_close_linearization_model.py`](../../tools/research/r05_admission_close_linearization_model.py) models a **revocable** permit in order to contrast it with the earlier **late-commit** permit model. Its abstract steps are:

```text
NEW → INVOKED
INVOKED (RUNNING and both budgets available) → RESERVED
RESERVED → BUILT | construction_failure
BUILT (still RUNNING) → PUBLISHED (abstract atomic GC-root + inbox commit)
PUBLISHED → successful TaskHandle return
close_begin: RUNNING → DRAINING; RESERVED/BUILT → REVOKED
REVOKED → owner ACK → closed failure response (no publication)
claim → worker execution → completed → post-dispatch returned → reap
close_drained only after no pending tokens and no executing/queued Tasks
acceptedCount reads only the physical committed acceptance counter
```

Bounded-state BFS covers **24** combinations: producers {1,2,3}, ingress {1,2}, retention {1,2}, workers {1,2}; each producer invokes at most one trySubmit. For every reachable abstract state it checks:
- `queued + pending <= ingressCapacity`
- `rooted + pending <= retainedCapacity`
- `accepted - completed == queued + executing`
- `rooted - returned == queued + executing`
- no uncommitted permit can become published after `DRAINING`
- `STOPPED` implies all publication and execution obligations drained.
- An **existential** path to `STOPPED` and all caller responses exists from each reachable state.

Three fixed-point/counter semantics counterexamples are explicitly checked; the new model also **positively witnesses constructed-but-revoked producers**, indicating resource/contract mismatch rather than proving a safe drop-in optimization.

**Explicit limitations:** The BFS is not a model of D's GC root reachability, cancellation exceptions, internal lock interleavings, condition predicates, arbitrary producer retries, real-time linearizability of every method history, release/acquire, native memory visibility, worker wake-tail, fairness, deadlock freedom under a stalled producer, or even eventual guaranteed shutdown under an adversarial scheduler. The root append and publication are intentionally one **idealized atomic** step; the real implementation has two separate protected actions that must be shown equivalent. The model checks a fixed close/commit linearization **hypothesis and local invariants**, not a completed linearizability proof.

Targeted [GitHub Actions CI — R0.5 Admission Close Linearization](https://github.com/alex-1974/concurrency-d/actions/runs/38366893505) **PASS**, Python syntax and all 24 bounded combinations with separate negative histories, **not** DMD/LDC compiler/runtime tests or native throughput. The original `r05_reservation_state_model.py` and its original CI evidence remain unchanged.

## Inbox cost: what is genuinely separated already?

**The earlier native XPS inbox inner-timing research already answers the narrow question of which *measured* substage dominates the instrumented inner hold.** There is no reason to repeat a native campaign just to rediscover the same observed stopwatch split.

[Original inbox research report, 2026-10-12](results/xps-inbox-submit-review-2026-10-12.md):
- Source HEAD `24d613a8d261bbb636052f0e3df728fbb0b77f68`, original archive `r05-xps-inbox-submit.tar.gz` SHA-256 `ea8d3939233bcae6ac56e276bc09207fafcd63df55e047c7c33bf59f13cc11e1`.
- 60 profiled child processes ×30k accepted tasks; all `NotificationPolicy.always`; in each profiled case `notifyCalls=accepted=30,000`; no skipped ingress notify.
- Medians of per-run **producer-side elapsed** nanoseconds per accepted Task (not CPU nanoseconds):
  - Wait to acquire **inner inbox mutex**: **579 ns**.
  - Inner mutex **hold** including probe: **1,273 ns**.
  - Enqueue, accepted count and generation: **53 ns**, a nested part of hold.
  - **`Condition.notify()` call** duration: **1,053 ns**, nested part of hold.
  - Enclosing outer `_pool.trySubmit()` bracket: **3,021 ns**.
  - Median of per-run `notifyNs / inboxHoldNs` is **82.82%**; `enqueueNs/inboxHoldNs` **4.11%**.
  - Median enclosing composite minus inner wait/hold residual **1,139 ns**; indicates that this profiler's nested clocks are **not** a complete additive decomposition.
- `TaskInbox.trySubmit()` performs all of enqueue, generation and `notify()` **while the inner inbox mutex is held**, and the outer Admission mutex remains held by its caller. Actual notification can lead to a wake or no wake, but the baseline's `_sleepers` count is maintained only for `waiterAware`, not `always`. No causal wake-usefulness or OS futex/kernelsyscall count exists in this dataset.
- The existing independently measured **uninstrumented** `waiterAware/always` A/B yielded median **0.9937×** across 60 heterogeneous same-round comparisons, **28/60** waiter-aware wins, mixed/poor 8-producer cases, and noisy idle-wake tail. [Prior wake policy report](results/xps-notification-ab-review-2026-10-11.md). It used a different source/victim-coverage setup: do not pool the magnitudes as if it were the exact same binary as inner profile.
- An even later same-source joint diagnostic revealed strong **AdmissionProbe observer effect**: [joint native XPS report](results/xps-joint-admission-worker-cost-review-2026-10-13.md), `joint_on/joint_off` same-binary median **0.7548×** with **29/30** profiler-on cases slower. **Do not extrapolate that measured 1,053 ns `notify` call implies a 1,053 ns per-Task speedup from suppression or an 83% reduction in real worker coordination.**

### Queue and lock mechanics vs CPU causation

- Each accepted Task's producer takes the **outer** Admission mutex, then the **inner** inbox mutex (separately for capacity and publication). Within the owned-pool route, no second producer can simultaneously hold outer while enqueueing, but worker claim/completion/park/generation traffic contends on the inner mutex.
- Slot enqueue and generation update are cheap *under intrusive stopwatch accounting*. `notify()` is the largest visible component of inner hold **under that instrumentation**.
- A `Condition.notify()` call's wall duration is **not** notification-to-worker-run latency and not a measured futex syscall duration. It cannot by itself distinguish (a) wakeups with no sleeper, (b) wakes that raced with a different worker claiming the Task, (c) scheduler preemption, or (d) kernel waiting overhead.
- Redesigning notification while keeping a generation-safe wait predicate demands a semantically fair **uninstrumented** same-source alternate mechanism and low-arrival/blocked-worker progress gates. The earlier waiterAware result is evidence *against* immediately spending on the same skip-notify approach; a new proposed algorithm needs a demonstrably distinct mechanism.

## Concrete decision after this research

| Candidate | Semantics status | Native performance evidence | Current decision |
|---|---|---|---|
| Keep current outer/inner mutex and always notify | Current existing acceptance/GC-rooting/close contract | Existing full-victim native XPS baseline; negative scaling acknowledged | **KEEP** |
| Early speculative allocation | Violates full/closed precheck allocation ordering | Not an equivalent A/B | **REJECT as current-contract optimization** |
| Reservation + late commit after DRAINING | Fixed COMMIT/close points inconsistent; acceptedCount & cancellation unresolved | None | **NO-GO as drop-in** |
| Revocable reservation + cancellation on close | Makes accepted cutoff easy in abstract, but allows constructed-then-rejected Tasks and stalled closer | None | **NO-GO without explicit contract change** |
| Defer close linearization to after outstanding tokens | Early CLOSED responses and accepted counter semantics require an additional protocol | None | **DEFER** |
| Skip notify using preexisting `waiterAware` logic | Generation-safe under its own protocol | Older uninstrumented native A/B neutral/no stable win | **KEEP always; do not retest unchanged** |
| Remove inner mutex, switch queue or introduce new publish/wake protocol | No correctness model nor equivalent root, capacity, wake/close proof | None | **DEFER** |

**Next meaningful work:** Re-examine any concrete *distinct* optimization idea **against** the exact ownership/close tests and an uninstrumented throughput control **before** creating more native measurement campaigns. A justified future design could explore an explicit submit batch API, task arena/ownership distinction, or call-site preparable task representation only if actual independent consumer semantics require it; these would be **new contracts**, not silent drop-in changes. Do not fabricate per-event CPU nanoseconds or a promised speedup based on stopwatch ratios.

Existing active Draft PR #35 and Issue #20 remain open and grandfathered. No code change to the production/executor hot path, no broad merge to `develop`, and no writes to other workspace repositories.
