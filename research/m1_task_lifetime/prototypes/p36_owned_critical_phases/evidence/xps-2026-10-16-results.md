# P36 XPS results — 2026-10-16

Archive SHA-256: `9846e8f2df4642255e200fdb6c849be1b2a4d997f325dd6496a92dd18fc46ae6` (receipt matched).

XPS-15, LDC 1.41.0, DUB 1.40.0, Linux 6.17.0-22, CPU governor powersave. Pinned HEAD `5bf7685ac723693c43fdab5489a9218d8596beb4`. Three rotated sessions, 9 measurement rounds, 27 profiles: 729 measured rows per arm (original, null, timed). Every profile accepted and completed 8192 tasks. All session-level original, paired null/timed, and three-arm validators passed.

**Interpretation:** instrumented four-producer owner phase medians per attempt (microseconds): Deferred capacity 0.730, construct 0.592, retain 0.090, publish 2.918 (publish 67.4% of four-phase sum); Managed 0.703, 0.594, 0.089, 2.976 (publish 68.2%). These are per-producer accumulated clock measurements, not proof that the original path is dominated by inbox publication. Nested queue, lock, wakeup and allocation effects remain unresolved.

**Important session confound:** original Deferred/4-producer median in sessions 1/2/3 was 40.86/41.60/64.43 ms; null 40.89/40.53/43.05 ms; timed 44.11/48.92/52.28 ms. Third-session original slowdown makes pooled arm speedup claims unsafe. Timed instruments perturb contention. Source behavior was not changed. P36 is diagnostic; no production optimization recommended. PR #38 Draft; ADR-0001 Proposed.
