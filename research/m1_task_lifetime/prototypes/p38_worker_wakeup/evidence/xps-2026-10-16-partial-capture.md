# P38 XPS partial capture — 2026-10-16

**Status: INCOMPLETE / NON-QUALIFYING.** This is a forensic note for the uploaded partial archive, not a completed P38 result.

Uploaded archive: `concurrency-p38-xps-20261016T140628Z.tar.gz`; computed SHA-256 `6bfd1a4fba743aebf62e5a32a31f69461b9fe5516f0e4c3b22864158d1d55a93` (no companion external receipt supplied). The archive is a flat set of entries without the final P38 archive/receipt markers.

It contains the three complete `session1-*.raw` logs, each ending in its respective P31/P38 benchmark PASS marker and containing 243 measured + 81 warmup rows. It includes `session1-original.csv`, `session1-null.csv`, compiler, CPU, git head/status and generated-source hashes. It does **not** contain `session1-timed.csv`, session validators, sessions 2 or 3, or an externally provided SHA-256 receipt. The timed CSV was locally reconstructed by exact filtering of the uploaded raw log; it is **not** an original capture artifact.

Independent checks on session 1: 243 unique measured profiles per arm; 27 profiles across 9 measured rounds; all rows have 8192 admitted and completed; original/null/timed task-execution and checksum fields match by row; all instrumented worker entries equal returns and are no greater than park calls; original and instrumented m0 have zero P38 counters.

Worker wait-entry medians per 8192 tasks in session 1 (across minimal/shared/sharded work and deferred/managed ownership):

| Producers | Null | Timed |
|---:|---:|---:|
| 1 | 3,615 | 4,022 |
| 2 | 5,998.5 | 6,065 |
| 4 | 6,691 | 6,628 |

These are worker **condition-wait entries**, not distinct OS wakeups or causal notification matches. Differences between independently instrumented arms are not performance evidence.

Follow-up: obtain the completed full P38 XPS archive and external SHA-256 receipt, or terminal failure output explaining the stopped capture. Preserve XPS working state and prior artifacts; do not overwrite or claim the three-session qualification succeeded.
