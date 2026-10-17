# P40 — post-wait worker outcome attribution

P39 XPS (2026-10-17) measured four notify sites, but notification calls cannot be mapped to waking workers. P40 classifies the **first worker-loop outcome after a real Condition.wait return**, not an inferred notification reason.

## Classification protocol

A worker-local pending flag is set after `parkUnlessChanged(observed)` only if the thread-local P38 `waitReturns` counter increased during that invocation. At the next worker-loop pass, the first selected branch consumes this flag and increments exactly one of: `localPop`, `inboxBatch`, `steal`, `repark`, `drained`. The `repark` class means the worker reached another park attempt before finding work; that attempt may skip the actual OS wait if generation changed. `inboxBatch` counts one batch outcome, not each task. A worker can execute other work during the loop before the first branch only where the source protocol already permits it; preserve branch order exactly.

If the worker takes a `parkUnlessChanged` path without calling `Condition.wait`, leave the pending state unchanged. If the next park call did wait, the previous pending event is classified as repark before arming the newly returned event. An event terminating after a `wait` return must classify as drained or another branch; assert post-join conservation: localPop + inboxBatch + steal + repark + drained == waitReturns. No per-notification causal pairing is claimed.

Use a source-pinned research overlay only, with worker-local counters. Preserve scheduler work order, generation predicate, root lifetimes and bounded ingress. First deliver source audit/generator and DMD/LDC correctness; only then CSV and native XPS.

## Qualification checkpoint (2026-10-17)

The first P40 runtime CI (commit `483cc41b68be4606ec5356fb2c2c3fa50732aa97`, workflow run `39026687815`) passed DMD 2.111.0 and LDC 1.41.0. Optimized P40 null/timed configurations and a rotated three-session XPS collector were added subsequently; their HEAD CI requires a separate check before native execution.

**Interpretation limit:** the current first-outcome flag describes the next worker-loop branch after a park invocation with at least one Condition.wait return. A Condition variable can return spuriously and repeat within the same park invocation; such multiple returns would not fit the one-flag-per-invocation classification and can trip conservation. Existing passing tests do not establish completeness under all spurious-wakeup schedules. Before interpreting counts as a one-to-one taxonomy of individual returns, extend the overlay to account for all returns within a park invocation (or explicitly count coalesced internal returns), with focused regression tests. Do not infer per-notification causality.

## P40.1 repeated wait-return conservation (2026-10-17)

A single `parkUnlessChanged` invocation can return from `Condition.wait` multiple times before its predicate exits. The source-pinned overlay now measures the exact delta of worker-local `waitReturns` around each invocation. For delta > 0, it records `delta - 1` as **internal re-waits** within the condition predicate loop and arms one pending worker-loop outcome. Delta 0 arms none.

**Semantic refinement:** `postRepark` now combines (a) internal predicate-loop re-waits and (b) reaching a subsequent park attempt without taking work. These are not independently distinguishable in the current CSV, so `postRepark` must not be described solely as a new park invocation. The conservation equation continues to count individual `Condition.wait` returns exactly once: the internal events plus the single classified final return.

P40 source preflight includes deterministic delta arithmetic cases 0, 1, 2, 3, 17. It is a structural/regression check, **not** a controlled scheduler test that induces spurious OS wakeups. The runtime CI must still pass for both baseline compilers before native measurement.
