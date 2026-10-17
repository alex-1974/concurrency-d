# P37 native XPS evidence — 2026-10-16

Research-only measurement; no production optimization or causal performance gate.

## Receipt and protocol

Archive: `concurrency-p37-xps-20261016T130623Z.tar.gz`. SHA-256 (matching the uploaded receipt): `cc3030a5e44070c336e3557f22429370b85ebb3bac48cbe87eb16d985b574`.
Native recorded Git HEAD `eea6f2a921d87e88d29a730aaed09c10bfbd1b0b`. LDC, XPS; three rotated sessions, nine measured rounds and three warmups per session; 27 profile combinations; 8192 tasks, four workers, ingress 128, retention 1024.

All 3 sessions contain 729 measured and 243 warmup rows per arm across original, null and timed. Each measured row accepts and completes exactly 8192 tasks. Session P31, P37 paired and P34 three-arm validator receipts pass. The supplied Git status is **dirty**: a local modification of `tools/research/m1_p36_xps.sh`, generated P37 modules and many previously present untracked benchmark files. Do not conflate that local state with a clean tree or overwrite it. Generated-source checksums and raw logs are in the archive.

## P37 timed phases

Pooled median producer-local accumulated time divided by the same row's admitted inbox calls, in microseconds per admitted task; 3 work kinds, 9 rounds and 3 sessions per mode and producer count.

| Producers | Mode | Inbox mutex wait | Ring publication | Condition.notify() |
|---:|---|---:|---:|---:|
| 1 | Deferred | 0.321 | 0.0002 | 0.412 |
| 1 | Managed | 0.300 | 0.0008 | 0.436 |
| 2 | Deferred | 0.395 | 0.0014 | 0.727 |
| 2 | Managed | 0.352 | 0.0016 | 0.731 |
| 4 | Deferred | 0.533 | 0.0029 | 0.885 |
| 4 | Managed | 0.513 | 0.0035 | 0.925 |

At four producers, among **only these three timestamped intervals**, about 63.1% is notify, 36.7% mutex wait and 0.2% ring publication, using pooled medians. These intervals are NOT a decomposition of the full P36 publish phase, which additionally includes validation and lock-release; measurement overhead can be large relative to queue work. All 486 measured owned-mode timed rows had a nonzero aggregate queue interval, although the CI-sized smaller run previously exposed clock-quantized zero. Do not interpret a near-zero interval as zero implementation cost.

## Observed wall-clock submit medians

Across all three work kinds/sessions and nine rounds, in milliseconds:

| Producers | Mode | Original | Null | Timed |
|---:|---|---:|---:|---:|
| 1 | Deferred | 19.04 | 16.88 | 21.00 |
| 1 | Managed | 19.37 | 17.70 | 21.02 |
| 2 | Deferred | 32.50 | 29.90 | 34.08 |
| 2 | Managed | 32.42 | 31.15 | 33.94 |
| 4 | Deferred | 37.99 | 39.42 | 41.78 |
| 4 | Managed | 40.91 | 40.25 | 42.93 |

Four-producer Deferred session medians (original/null/timed): session 1 = 37.43/36.47/41.52 ms, session 2 = 37.69/39.34/42.45 ms, session 3 = 38.92/42.30/41.78 ms. Comparing independent arms does **not** establish a performance gain. Measured rows with retries: original 10/729; null 6/729; timed 1/729. Retry differences are legitimate because each arm runs independently.

## Conclusion

P37 native data strongly motivate further **research-only** attribution of condition-variable notify, worker wakeup and inbox-mutex contention. A `notify()` duration is not necessarily the CPU cost of waking a worker; scheduling, contention, and timestamp quantization must be separated. Do not change wake-generation semantics, the GC-root-before-publication guarantee, FIFO ordering or production code on the strength of these results. PR #38 remains Draft; ADR-0001 remains Proposed.
