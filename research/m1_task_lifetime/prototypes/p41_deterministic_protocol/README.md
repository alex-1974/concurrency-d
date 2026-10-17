# P41 — bounded deterministic wakeup/close protocol model

**Research-only.** P41 starts with a finite-state *abstract model*, not a new production scheduler, not a real Thread/Condition test, and not a proof for arbitrarily many workers.

`tools/research/m1_p41_protocol_model.py` audits the current production pool source for the generation/condition predicate and enumerates reachable short atomic-step interleavings of one producer, one worker and one possible task. It considers ticket capture, publish, close, claim+completion, actual wait entry, up to two **artificial spurious returns**, predicate rechecks and exit. It checks that no waiting state with a false predicate lacks an exit transition and that completion obligations stay bounded. Exhaustive exploration is only over the **specified bounded model** and its simplifications; the source audit is textual, not a semantic equivalence proof.

The test does not execute operating-system condition variables, does not exercise multi-worker steals or GC-root lifetime and does not replace P40's existing runtime gates. Deterministic model-level artificial spurious returns must not be described as an injected OS-level spurious wakeup.

Next qualification: a source-pinned **D runtime barrier test**, with an injected wrapper only in research overlays, to force close-before-park and close-during-park while preserving the generation predicate. Only then consider native measurements or scheduling variants. P37–P40 XPS evidence stays preserved.

P41 is intended to establish confidence in the existing close/publish ordering, not justify removing notification calls. PR #38 remains Draft; ADR-0001 remains Proposed.

## Ordered regression scenarios

`tools/research/m1_p41_ordered_scenarios.py` reuses the same state transitions but insists on six explicit orderings: close before ticket, close between ticket and park, close during wait, two artificial spurious returns followed by close, publication before park, and publication while waiting followed by close and completion. Each has an expected bounded terminal state. This is a deterministic *model-level* regression, not yet a source-pinned D thread-barrier test. CI runs both model enumerator and scenarios on the DMD/LDC matrix (Python test itself is compiler-independent).
