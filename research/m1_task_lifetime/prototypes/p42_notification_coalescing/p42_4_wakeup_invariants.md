# P42.4 — Unified wakeup invariants and evidence gates

Date: 2026-10-17. **Research contract candidate, not production API or proven global liveness contract.**

## Source of truth and scope

The unchanged `source/concurrency/internal/submission_pool.d` is authoritative for the existing behavior. The bounded P42.1 model, separated ticket/search/park P42.2 model, and local-handoff P42.3 model are *supporting experiments*; green CI validates those **models**, not arbitrary production schedules.

## Existing transitions and obligations

| Event | Current production transition | Required wake/progress property | What P42 models establish |
|---|---|---|---|
| Accepted inbox publication | Under inbox mutex: write slot, increment used/accepted and generation, call `notify()`. Rejected submissions must not create obligations. | An eligible worker can eventually claim each accepted obligation; no worker may sleep forever solely because it searched before the publication. | P42.1 and P42.2 explore bounded two-producer/two-worker cases; silent publication has queued-work/all-waiting counterexample. |
| Inbox batch claim | Under inbox mutex, remove up to 8 entries; later enqueue all but first in worker-owned deque; execute first. | Removing an inbox slot does **not** discharge accepted execution obligation; local work must remain reachable. | P42.3 isolates a two-task handoff, not a production batch schedule. |
| Local-deque handoff | If any tasks were enqueued in worker-owned deque: `announceLocalWork()` increments generation and calls `notify()`. | Idle thieves that searched before the handoff must be offered a new search opportunity. | P42.3 dropped-local-notify control demonstrates **delayed steal opportunity**, not necessarily a deadlock. |
| Close | Under inbox mutex, close flag, generation increment, `notifyAll()`; controlling thread joins workers. | Reject later admission; workers waiting or entering park must eventually exit after all obligations are complete. | P41 bounded/model/native fixtures cover selected interleavings; not a complete multi-worker proof. |
| Final completion after close | Under inbox mutex, completed++, and when completed==accepted increment generation and `notifyAll()`. | Workers asleep while outstanding tasks execute must be released once drain predicate becomes true. | P41 verifies selected closure paths; unaltered final broadcast remains mandatory in P42 candidate. |

### Proposed invariants for any future notification change

**W1: Obligation conservation.** Accepted counts successful ingress only; successful claims do not constitute execution. For successful joined execution without supported failure paths, every accepted record must be executed exactly once and all obligations discharged before reclamation.

**W2: Search-to-park safety.** A worker captures generation before searching inbox/stealable work. The actual condition wait is entered only while the inbox mutex proves generation unchanged, inbox empty, and shutdown not fully drained. Every new runnable publication capable of invalidating a completed search must either make the predicate false or ensure a legitimate waking transition. A bare notification is not a durable token.

**W3: Two distinct runnable domains.** Inbox slots and owner-local deque elements are not interchangeable: `_used==0` does **not** imply no executable work. Local-deque handoff has its own generation increment and notification today. Publish-site coalescing proposals must not automatically alter `announceLocalWork()`.

**W4: Liveness and concurrency.** Suppressing a notification is permitted only with a separately justified progress argument covering the last running worker, all workers asleep, idle-to-busy transition, concurrent producers, and competing stealers. A wakeup count by itself is not proof of progress.

**W5: Shutdown completion.** Close and last-completion broadcasts remain unchanged unless a separate correctness proof covers sleepers, in-flight work, final count transition and join. Any policy that permits indefinitely parked workers with outstanding obligations fails.

**W6: Lifetime and safety.** Accepted TaskRefs are non-owning in the underlying pool. Preserve caller storage through `closeAndJoin()`, root ordering in higher ownership layers, FIFO admission and bounded capacity. Optimization must not weaken safety for throughput.

## Dangerous inference to avoid

A `notifyIfWaiting` policy may appear valid in P42.2's idealized wait-enrollment model because generation capture, enrollment and notification are abstract atomic transitions. In the real implementation the worker also owns a private deque and searches peers outside the inbox mutex. Therefore *no proof of safe notification suppression follows* from P42.1–P42.3. The P42.3 negative case only shows lost parallelism; it is not a global deadlock witness. Conversely the publish-silent controls show why unconditional dropping is unsound in the bounded inbox scenario, not the quantitative cost of current notify.

## Adversarial schedule checklist for P42.5

1. Producer publishes just before and just after a worker's ticket capture.
2. Producer publishes after external empty search but before the worker acquires inbox mutex to park.
3. Producer publishes while one or all workers are already waiting, including repeated publications.
4. A worker claims a full batch, moves work to local deque while other workers are waiting; a stealer races owner-local pop.
5. Last runnable worker finishes while some unclaimed inbox or local work remains.
6. Close races with admission, worker parking, batch claim, and last task completion.
7. Repeated condition returns with unchanged predicate; no busy loop or lost accounting.
8. Full inbox rejection never creates a completion debt and retains caller ownership.

Before implementing any overlay, encode at least the first six as explicit source-pinned schedule probes or a sufficiently precise finite-state model with a counterexample oracle. Then establish identical progress semantics under DMD and LDC; only afterwards compare native uninstrumented wall time and tail latency.

**Decision: P42.4 documents research-only obligations. No alternative notify policy is qualified; no production optimization is approved.** PR #38 remains Draft; ADR-0001 remains Proposed.
