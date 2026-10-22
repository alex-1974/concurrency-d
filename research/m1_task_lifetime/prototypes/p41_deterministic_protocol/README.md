# P41 — bounded deterministic wakeup/close protocol model

**Research-only.** P41 starts with a finite-state *abstract model*, not a new production scheduler, not a real Thread/Condition test, and not a proof for arbitrarily many workers.

`tools/research/m1_p41_protocol_model.py` audits the current production pool source for the generation/condition predicate and enumerates reachable short atomic-step interleavings of one producer, one worker and one possible task. It considers ticket capture, publish, close, claim+completion, actual wait entry, up to two **artificial spurious returns**, predicate rechecks and exit. It checks that no waiting state with a false predicate lacks an exit transition and that completion obligations stay bounded. Exhaustive exploration is only over the **specified bounded model** and its simplifications; the source audit is textual, not a semantic equivalence proof.

The test does not execute operating-system condition variables, does not exercise multi-worker steals or GC-root lifetime and does not replace P40's existing runtime gates. Deterministic model-level artificial spurious returns must not be described as an injected OS-level spurious wakeup.

Next qualification: a source-pinned **D runtime barrier test**, with an injected wrapper only in research overlays, to force close-before-park and close-during-park while preserving the generation predicate. Only then consider native measurements or scheduling variants. P37–P40 XPS evidence stays preserved.

P41 is intended to establish confidence in the existing close/publish ordering, not justify removing notification calls. PR #38 remains Draft; ADR-0001 remains Proposed.

## Ordered regression scenarios

`tools/research/m1_p41_ordered_scenarios.py` reuses the same state transitions but insists on six explicit orderings: close before ticket, close between ticket and park, close during wait, two artificial spurious returns followed by close, publication before park, and publication while waiting followed by close and completion. Each has an expected bounded terminal state. This is a deterministic *model-level* regression, not yet a source-pinned D thread-barrier test. CI runs both model enumerator and scenarios on the DMD/LDC matrix (Python test itself is compiler-independent).

## Native D Condition gate

`p41_condition_runtime.d` is a standalone **real D Thread/Mutex/Condition** regression. Four bounded cases cover close before generation snapshot, close after snapshot but before worker park, close after an actual wait entry, and an unchanged-state notifyAll followed by close. Mutex-protected counters establish the wait-entry barrier; each case joins its thread and conserves wait entries/returns. The bounded runner `tools/research/m1_p41_native_condition.sh` compiles under DMD/LDC and applies a 30-second external timeout. This standalone fixture deliberately does **not** exercise the source-pinned `TaskInbox` or `SubmissionWorkerPool`; the Python protocol source audit is performed alongside it. A source-pinned full-pool thread barrier test remains an open qualification step.

## Source-pinned real pool close gate

`tools/research/m1_p41_real_pool_close.sh` builds P38's exact-source research pool and runs `consumer/p41_real_pool_close.d` under a timeout. Eight fresh four-worker pools are closed and joined, with alternating attempts to observe idle parking. Accepted/completed counts remain zero. This tests actual worker creation, close and join but **does not force a worker to wait** (a bounded observation loop is not a synchronization barrier), and it does not test accepted-task execution or controlled publication races. The stronger deterministic full-pool barrier remains open. The new CI result must be checked before claiming qualification.

## Publish after observed real-pool wait

The new `p41_wait_publish.d` fixture uses the pinned P38 pool with one worker and one task. It observes `parkCount() > 0`, publishes a task, then closes and joins. Across twelve cases it checks one acceptance, one completion, and exactly one execution. The observation is bounded and synchronized via the inbox counter accessor. **It proves a wait-entry counter was reached, not that the worker remains asleep at the exact instant of publication.** The deterministic ticket-to-publish barrier remains a separate scenario. Both DMD and LDC CI must be checked before qualifying this fixture.

## P41 native predicate re-wait strengthening

The standalone native `Condition` fixture now explicitly waits for a **second** mutex-observed wait entry after sending a notification **without** changing the generation. It asserts that at least one wait returned but the worker had not completed, then closes, joins and checks wait-entry/return conservation. This exercises a repeated real `Condition.wait` cycle (not a randomly occurring OS spurious wakeup). It is still a standalone fixture rather than a full-pool forced-wait proof. The bounded process timeout remains in place.
