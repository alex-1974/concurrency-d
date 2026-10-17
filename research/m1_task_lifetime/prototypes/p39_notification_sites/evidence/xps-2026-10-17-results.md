# P39 native XPS evidence — 2026-10-17

Research-only; no production change, no wakeup optimization claim.

Archive: `concurrency-p39-xps-20261017T103848Z.tar.gz`; SHA-256 `03f853087edca1582e7511476700198a771c107e22f67d29b1f8c742471e6460`, verified against separately uploaded receipt. Recorded git HEAD `db96dae18dc10ac51c2b93a6158d7d215edb7bcb`; worktree dirty (existing research artifacts preserved). Native compiler **LDC 1.42.0** (different from CI baseline 1.41.0).

Three complete rotated sessions. Each original/null/timed arm has 243 measured and 81 warmup rows per session; 729 measured rows per arm. All nine original / paired / three-arm per-session validation receipts pass, including P31/P34/P37/P38/P39 checks. All measured profiles have 8192 accepted/completed/executed tasks, matching checksums.

## Median notification and wait counts

Pooled per 8192-task measured row over three work classes, three sessions and nine rounds. Each producer/owner/arm median represents 81 rows.

| Producers | Owner | Arm | publish | local work | closeAll | finalAll | parkCalls | waitEntries |
|---:|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Deferred | null | 8192 | 1609 | 1 | 0 | 2672 | 2163 |
| 1 | Deferred | timed | 8192 | 1908 | 1 | 0 | 4924 | 3394 |
| 1 | Managed | null | 8192 | 1590 | 1 | 0 | 3238 | 2540 |
| 1 | Managed | timed | 8192 | 1930 | 1 | 0 | 5170 | 3520 |
| 2 | Deferred | null | 8192 | 1631 | 1 | 0 | 3144 | 2580 |
| 2 | Deferred | timed | 8192 | 1913 | 1 | 0 | 7669 | 5635 |
| 2 | Managed | null | 8192 | 1603 | 1 | 0 | 3350 | 2703 |
| 2 | Managed | timed | 8192 | 1901 | 1 | 0 | 7733 | 5578 |
| 4 | Deferred | null | 8192 | 1655 | 1 | 0 | 3454 | 2810 |
| 4 | Deferred | timed | 8192 | 1867 | 1 | 0 | 8176 | 5903 |
| 4 | Managed | null | 8192 | 1626 | 1 | 0 | 3713 | 2959 |
| 4 | Managed | timed | 8192 | 1858 | 1 | 0 | 8465 | 6190 |

Final completion notifyAll was invoked in a minority of measured owned rows (null Deferred 11/243, null Managed 3/243, timed Deferred 4/243, timed Managed 2/243); typical row median zero. One close notifyAll occurred in every owned row. One publish notify per accepted task is conserved.

## Submission time medians (milliseconds)

| Producers | Owner | original | null | timed |
|---:|---|---:|---:|---:|
| 1 | Deferred | 26.459 | 29.485 | 37.859 |
| 1 | Managed | 33.807 | 31.415 | 40.599 |
| 2 | Deferred | 51.203 | 36.636 | 51.553 |
| 2 | Managed | 53.452 | 37.183 | 49.024 |
| 4 | Deferred | 65.879 | 40.123 | 52.669 |
| 4 | Managed | 74.978 | 41.105 | 54.609 |

Substantial cross-arm and session variability is expected; timing and counters perturb contention and scheduling. The timed arm also changes the number of local-work notifications and wait entries, so these are **not invariant workload events** or evidence of a faster production policy.

## Interpretation

A condition notify call cannot be paired with a specific wait return from these aggregated counters. notifyAll call counts are not the number of awakened threads. Race-sensitive closure and final-completion behavior must remain intact; no scheduling or ownership contract change is justified. Next study should classify return-to-search and successful-work outcomes with worker-local counters while preserving source pins and original synchronization.
