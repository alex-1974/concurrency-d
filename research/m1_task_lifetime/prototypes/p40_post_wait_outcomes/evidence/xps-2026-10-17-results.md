# P40.1 native XPS results — 2026-10-17

**Diagnostic research only.** Archive `concurrency-p40-xps-20261017T115421Z.tar.gz`. SHA-256 `5fa641a5c698043b4d1c9288bf50317be7d1046732194d9e44e3340e3d537b16`, independently computed and matched to separately uploaded receipt. Native recorded Git HEAD `a16549c5b96516d668e5a08ba50790750e990657`; LDC **1.42.0**, unlike 1.41.0 CI baseline. Worktree had pre-existing dirty research artifacts.

Three full rotated sessions; original, null, timed each has 729 measured rows (243 per session), 243 warmup rows. All nine validator receipts (P31 original, P40/P39/P38/P37 paired, P34 three-arm) passed. P37 unresolved short queue time intervals: session 1 = 7, session 2 = 0, session 3 = 4 (clock granularity, not task failures). The P40 conservation equation matched in all **972 owned measured rows** (486 each for null/timed); M0 rows correctly have zero instrumented outcomes.

## Outcomes

Median per 8192 tasks, pooled over Deferred/Managed ownership, three workload classes and all sessions (162 rows per producer/arm):

| Producers | Arm | wait returns | postInbox | postSteal | postRepark | postDrained | postLocal |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | null | 2534 | 1767 | 142 | 610 | 4 | 0 |
| 1 | timed | 3600.5 | 1864 | 463 | 1268 | 4 | 0 |
| 2 | null | 3205.5 | 2165 | 152.5 | 880.5 | 4 | 0 |
| 2 | timed | 5791 | 2871.5 | 493 | 2278.5 | 4 | 0 |
| 4 | null | 3110.5 | 2114 | 141.5 | 823.5 | 4 | 0 |
| 4 | timed | 6091.5 | 3133 | 476 | 2457.5 | 4 | 0 |

Totals over all owned measured rows: null = 1,393,203 wait returns (960,270 inbox, 67,085 steal, 363,957 repark, 1,891 drained); timed = 2,198,328 (1,207,671 inbox, 187,265 steal, 801,465 repark, 1,927 drained). Totals conserve exactly. PostLocal is zero for all instrumented rows.

`postRepark` includes internal repeated `Condition.wait` returns **and** reentering the parking path without doing work; it must not be interpreted as solely a new sleep operation. `postInbox` is a batch-claim outcome, not per-task useful work. `postDrained` counts loop exit after a wait return, not number of shutdown broadcasts.

Null/timed instrumentation materially perturbs contention and work search; their differing counts are not evidence of a production scheduling improvement or regression. Per-notification causality and OS-level wakeups remain unmeasured.

**Conclusion:** P40.1 establishes exact five-way return accounting in observed runs, not a general proof against all spurious-wakeup interleavings. Preserve generation predicate and shutdown semantics; no production change proposed. PR #38 Draft, ADR-0001 Proposed.
