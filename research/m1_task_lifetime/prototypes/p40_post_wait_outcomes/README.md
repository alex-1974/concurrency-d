# P40 — post-wait worker outcome attribution

P39 XPS (2026-10-17) measured four notify sites, but notification calls cannot be mapped to waking workers. P40 classifies the **first worker-loop outcome after a real Condition.wait return**, not an inferred notification reason.

## Classification protocol

A worker-local pending flag is set after `parkUnlessChanged(observed)` only if the thread-local P38 `waitReturns` counter increased during that invocation. At the next worker-loop pass, the first selected branch consumes this flag and increments exactly one of: `localPop`, `inboxBatch`, `steal`, `repark`, `drained`. The `repark` class means the worker reached another park attempt before finding work; that attempt may skip the actual OS wait if generation changed. `inboxBatch` counts one batch outcome, not each task. A worker can execute other work during the loop before the first branch only where the source protocol already permits it; preserve branch order exactly.

If the worker takes a `parkUnlessChanged` path without calling `Condition.wait`, leave the pending state unchanged. If the next park call did wait, the previous pending event is classified as repark before arming the newly returned event. An event terminating after a `wait` return must classify as drained or another branch; assert post-join conservation: localPop + inboxBatch + steal + repark + drained == waitReturns. No per-notification causal pairing is claimed.

Use a source-pinned research overlay only, with worker-local counters. Preserve scheduler work order, generation predicate, root lifetimes and bounded ingress. First deliver source audit/generator and DMD/LDC correctness; only then CSV and native XPS.
