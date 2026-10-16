# P35 — Owned executor contention and allocation instrumentation protocol

2026-10-15. **Design gate only.** No timing result, no claim of dominant lock contention.

## Evidence carried forward

P31, P33 and P34 use 8,192 accepted tasks, four workers, ingress 128 and retention 1,024. The P34 original/null/timed control experiment shows the 1→2→4 producer submission-time increase persists in original P31. Fewer than 2% of measured rows require retry, so rejected admission alone is not a sufficient explanation. P34 wrapper timing measures nested costs and is not a pure owner-lock clock. [P34 native evidence](../p34_owned_admission_cost/evidence/xps-2026-10-15-results.md).

## Source contract

Pin original `source/concurrency/internal/owned_task.d` blob `e74d6a73f956c562eab176e27687a47249f5815d`, `submission_pool.d` blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, P29/P31 research consumer blob `d19405f2ef0f8d7159978174c1a919ed6d66764f` and the P23 generated owner source mechanics. Do not change `source/`, P29 generational tracking, process GC roots, worker join, task callbacks or accepted-task retention. Existing P23 generator must remain independently testable.

The `OwnedTaskExecutor.trySubmit(F)` body has nested owner and inbox mutex operations. On successful admission it constructs a result cell, handle and owned node under the owner mutex, retains the node, then calls inbox submission while the owner mutex remains held. Manager `publish(F)` acquires its mutex before and after calling the executor but does **not** hold that manager mutex across the entire call.

## P35 experimental arms

1. **Original** source-pinned P31.
2. **Null** generated P23 owner and P31 wrapper with the same sample counters but no clock reads.
3. **Timed** generated P23 owner and wrapper with identical task semantics and clocks around carefully delimited owner lock acquisition, inside-lock allocation/construction, retention and nested inbox submission.

For each arm validate rejected and accepted paths, native completion and worker join; for managed mode, validate P29 operation counts, generation protections and successful root reclamation. Source transformations must refuse unexpected anchors. Any injected timestamp inside a locked section changes contention: report observer effects and paired round ratios, never treat measured lock-wait or allocation duration as the untouched cost.

## Method and stop rules

- Thread-local telemetry, aggregated only after producer join. Never introduce shared hot-path statistics counters; prove thread ownership. If direct owner instance instrumentation is shared by producers, use per-thread slots or another verified no-race design.
- Track successful admission and rejection separately. Clock overhead can change the rate of reaping. Do not infer GC allocator call count from three `new` expressions; measure allocated bytes separately from live retention.
- DMD 2.111.0 and LDC 1.41.0 compiler gates, including negative/safety gates already inherited. Native XPS LDC `-O3`, three sessions with rotated original/null/timed process order, 3 warm-up + 9 measured rounds per session, full 27-profile work matrix, raw CSV and checksum.
- Any slowdown with instrumented critical-section clocks disqualifies direct subtraction of accumulated wait/hold times from wall-clock submission. Promote no production optimization without a semantics-matched uninstrumented candidate-vs-baseline native result.
- Abort or fail-stop on unproven native join. Retention roots are cleared only following proven native quiescence.

**Status (2026-10-16):** source-pinned P35 generated P23 owner and exact P31 consumer have an initial producer-TLS owner lock wait/hold probe. Two DUB configurations (null/timed) and full 27-cell matrix validation are wired into the compiler CI. **Compiler qualification is still pending**; no native XPS evidence exists, and no allocator-versus-retention subphase measurement has been added. The timestamped critical section may perturb the result, so no uninstrumented wait-time or optimization claim follows. Draft PR #38 and ADR-0001 remain unpromoted.

## P35 hold-clock correction (2026-10-16)

The first native XPS attempt stopped during null/timed validation with `P35 timed timestamps missing`. Audit found `scope(exit)` inside a nested `version(P35Timed)` block; it executed at exit of that *inner block*, not at release of the enclosing synchronized block. Corrected generated owner code places the exit guard at synchronized-block scope. A zero total lock-wait counter is valid for uncontended acquisitions; timed hold durations must still be positive on non-M0 owner paths. The failed run is **not valid native evidence**, and its partial output must not be interpreted as owner-lock time. Re-run DMD/LDC CI and collect new source-pinned native XPS evidence before any conclusion.
