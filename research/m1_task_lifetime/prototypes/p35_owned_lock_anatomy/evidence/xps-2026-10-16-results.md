# P35 native XPS results — 2026-10-16

**Research evidence only.** No production optimization or uncontended mutex causal claim.

## Integrity and provenance

- Uploaded archive `concurrency-p35-xps-20261016T062637Z.tar.gz` independently matches supplied SHA-256 receipt: `ff88f8dc694aad5cdbbd7b4616950382228943a99b1a39a79a3e186234d5057f`.
- Measured HEAD `b78538ed12e1ec77fb54db621954d5794fb78d8a`; owner blob `e74d6a73f956c562eab176e27687a47249f5815d`; pool `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`; consumer `d19405f2ef0f8d7159978174c1a919ed6d66764f`. Generated owner SHA256 `6a7b8e4e1f1154dfbf2a1b9f2beb418f85ce3b3d10b11f4da76e88ac1a1f47d0`, generated consumer SHA256 `a2ada4c9b52496dd9f825a2b41e7142e60aad2635d973270bb0164bdbdbd7749`.
- Native Intel Core i7-9750H, Ubuntu 6.17.0-22, LDC 1.41.0 (LLVM 19.1.7), DUB 1.40.0, powersave governor. CPU0 frequency *snapshots* 4.171 GHz start and 3.100 GHz end; no continuous frequency or thermal control. Existing unrelated untracked worktree data documented in metadata, including generated temporary P35 files.
- Three sessions × three arms (original P31, P35 null, P35 timed), 3 warmups + 9 measured rounds/session, 27 profile dimensions, 8,192 tasks, 4 workers, ingress 128, retention 1,024. Exactly **729 measured rows per arm**; three P35 null/timed validation receipts and three three-arm validation receipts passed. All accepted and completed counts match requested count. Non-M0 timed hold counters positive; M0 has no P35 owner timings.

## Minimal work: medians of 27 measured rounds

Submission interval: ms; mutex wait and hold: aggregate producer TLS nanoseconds divided by attempts **within each round**, then median across rounds. Distinct numbers are not independently paired or additive wall time.

| Owner | Producers | Original ms | Null ms | Timed ms | Timed wait µs/attempt | Timed hold µs/attempt |
|---|---:|---:|---:|---:|---:|---:|
| M0 | 1 | 17.70 | 18.00 | 18.87 | n/a | n/a |
| M0 | 2 | 32.21 | 36.45 | 38.35 | n/a | n/a |
| M0 | 4 | 40.47 | 40.38 | 41.79 | n/a | n/a |
| Deferred | 1 | 19.11 | 18.10 | 24.75 | 0.00 | 2.81 |
| Deferred | 2 | 33.97 | 36.38 | 40.48 | 4.51 | 3.79 |
| Deferred | 4 | 42.88 | 41.42 | 46.17 | 15.04 | 4.37 |
| Managed | 1 | 19.47 | 20.21 | 21.39 | 0.00 | 2.36 |
| Managed | 2 | 35.60 | 41.44 | 40.44 | 4.55 | 3.76 |
| Managed | 4 | 42.29 | 41.14 | 47.59 | 15.35 | 4.41 |

For shared_atomic and sharded_atomic, measured four-producer wait medians are ~14.66–15.10 µs/attempt (deferred) and ~15.02–15.10 µs/attempt (managed), with hold medians ~4.34–4.42 µs/attempt. Thus the pattern replicates across work variants.

## Observer effect and limits

Across all work types aggregated by producer and owner, four-producer median submission intervals: M0 original/null/timed 40.47/40.38/41.79 ms; deferred 41.15/40.76/46.06 ms; managed 42.16/42.14/47.57 ms. Null and original are similar here, while Timed adds ~13% over Null for deferred and managed. Individual work/round ratios vary; this is **not** an instrument overhead correction.

Measured rows with retries (attempts > requested tasks): 19/729 original, 8/729 null, 4/729 timed; maximum excess attempts 89/288/841 respectively. Retries are sparse by row but can be much larger in particular outliers; avoid a categorical no-retry claim.

Owner wait grows strongly with producer count while hold grows more slowly in the **instrumented** P35 code. This supports an executor mutex contention hypothesis, **not** proof of original-code mutex wait dominance. Timestamp instrumentation changes scheduling/lock duration; TLS hold sums are overlapping producer-local times, not elapsed wall-clock components. The P35 owner probe only times the complete critical section; it does not isolate allocation, retention, reaping, nested inbox lock, or manager locks.

## Next

Source-pin an independently controlled *semantics-identical* experiment to separate successful-admission allocation/retention/inbox costs, preserve task lifetime, verify DMD/LDC correctness and repeat rotated native XPS comparisons. Do not migrate speculative optimizations to production. PR #38 remains Draft; ADR-0001 remains Proposed.
