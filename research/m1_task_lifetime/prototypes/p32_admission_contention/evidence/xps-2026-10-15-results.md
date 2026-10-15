# P32-C native XPS matched M0 control / mutex-timed evidence

**Date:** 2026-10-15. **Research only.** This is a diagnostic comparison, **not** proof of an uninstrumented mutex bottleneck or production optimization.

## Provenance

- Uploaded archive: `concurrency-p32-xps-20261015T192754Z.tar.gz`
- Independent uploaded-archive SHA-256: `9d4ffb8acbbfa2acd068eb4bfe0ab1ed382e3b208cbc35a879c5dd747252daa4`
- Measured commit: `26bc9f47ea0d4d1ac8121d32cff9ee659561d157`
- Original M0 pool blob: `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`; owned-task blob: `e74d6a73f956c562eab176e27687a47249f5815d`
- Generated P15-timed pool SHA-256: `32c618e1e290008be62bec0fa0eca8f1a05537e0f4227e46895ed85c5d0cd7ea`
- Native Dell XPS 15, Intel Core i7-9750H; LDC 1.41.0 / frontend DMD 2.111.0 / LLVM 19.1.7, DUB 1.40.0, Linux 6.17.0-22-generic, `powersave` governor; release `-O3`.
- CPU0 frequency start/end were 4,275,061 / 4,099,996 kHz; snapshots, not an effective continuous-frequency or thermal control.
- Local `git status` had unrelated untracked experiment binaries; the archive documents them. No tracked-source change is evident from status, but their impact cannot be independently excluded.
- An accompanying external `.sha256` receipt was not submitted: the archive hash above was computed directly on the received bytes.

## Completeness and semantics

Each of three sessions contains 36 original-M0 control CSV rows and 36 P15-timed generated-M0 rows (3 warm-up + 9 measured rounds, for each of 1/2/4 producer counts). Total 216 rows, of which 162 are measurement rows. Each arm uses 8,192 unique TaskRefs, four native workers and ingress 128. Both variants execute the identical task callback with the same per-record exactly-once oracle and successful native join. The per-session supplied analyzers all report `P32_B_MATCHED_WORK_PASS rounds=9`. Records and schema were independently parsed from the archive.

**Important semantic distinction:** the P32 consumer directly uses internal M0 `SubmissionWorkerPool` with borrowed record storage and weaker independent failure/ownership semantics than the owned P23/P29 modes in P31. P32 is a mutex-mechanism test, not an end-to-end equivalent replacement for P29.

## Submission phase median per session

Milliseconds; ratios are medians of within-round timed/control ratios, not quotients of displayed medians.

| session | producers | untouched median ms | timed median ms | paired timed/control |
|---|---:|---:|---:|---:|
| 1 | 1 | 5.321 | 11.008 | 2.204 |
| 1 | 2 | 4.016 | 8.780 | 2.029 |
| 1 | 4 | 4.644 | 8.971 | 1.962 |
| 2 | 1 | 4.904 | 10.848 | 2.137 |
| 2 | 2 | 3.981 | 7.258 | 1.716 |
| 2 | 4 | 4.547 | 8.943 | 2.090 |
| 3 | 1 | 5.222 | 10.745 | 2.112 |
| 3 | 2 | 4.015 | 7.190 | 1.755 |
| 3 | 4 | 4.691 | 9.189 | 1.982 |

The invasive timed version is approximately **1.7–2.2×** the untouched version in this workload. This substantial observer effect prohibits interpreting its mutex wait/hold values as ordinary uninstrumented M0 costs.

Unlike P31's owned-task submission workload, P32 direct-M0 control is faster with two producers than one. This does not refute P31: task representation, allocation/retention and producer work differ substantially. Do not collapse these into one causal scaling curve.

## Timed-copy mutex diagnostic only

Per-session medians of per-submission-attempt average durations (`submit_wait_ns/submit_calls`, `submit_hold_ns/submit_calls`):

| session | producers | measured wait ns/call | measured hold ns/call |
|---|---:|---:|---:|
| 1 | 1 | 604.9 | 146.2 |
| 1 | 2 | 1138.4 | 83.0 |
| 1 | 4 | 1885.9 | 73.0 |
| 2 | 1 | 588.0 | 141.5 |
| 2 | 2 | 955.3 | 52.2 |
| 2 | 4 | 1813.6 | 74.9 |
| 3 | 1 | 586.1 | 142.8 |
| 3 | 2 | 984.4 | 54.6 |
| 3 | 4 | 1947.6 | 75.3 |

Observed wait rises with producer count **in the timed copy**. All aggregate wait/hold times are sums over concurrently executing threads and must **not** be equated to serial wall-clock time or simply subtracted from submission duration. The `P15Timed` instrumentation reads clocks and updates counters while holding the mutex, altering scheduling and contention.

Control median retries are zero for one and two producers, but four-producer median retries are nonzero: session medians 306 / 348 / 1194 attempts beyond accepted tasks. Thus P32 and P31 have distinct full-queue/backpressure characteristics.

## Decision and next gate

**KEEP:** P29 roots, generational management and native shutdown proof requirements. No production optimization or scheduler substitution.

**SUPPORTED:** the instrumented M0 has larger observed mutex acquisition delay as producer count increases; this occurs with large instrumentation overhead. Original M0's 1→2 behavior demonstrates that the cause of P31 slowdown cannot be inferred from a generic producer-scaling slogan.

**NOT SUPPORTED:** mutex waiting is the dominant source of P31's large slowdown, numerical wait times of uninstrumented M0, fair P32-versus-P31 speed comparison, or availability-safe native recovery.

**Next controlled investigation:** isolate producer-start/stop overhead and record/ownership creation within the *P31 actual owner path*, and use lower-perturbation paired controls (e.g., externally sampled profiling) before choosing a mutex optimization. Preserve the exact P31 semantics in the candidate-vs-baseline comparison. No new release or API commitment.

CI for evidence commit must be evaluated at the new HEAD; the preceding run `38794011105` was still queued at time of review.
