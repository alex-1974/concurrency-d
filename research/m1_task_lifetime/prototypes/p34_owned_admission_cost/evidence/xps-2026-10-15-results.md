# P34 native XPS: three-arm owned submission observation

Date: 2026-10-15. **Research evidence, no production decision.**

## Provenance and integrity

- Uploaded `concurrency-p34-xps-20261015T211310Z.tar.gz` with accompanying `.sha256` receipt: independently recomputed SHA-256 matches: `2de9ac28457dd54fa474daa6318fa5522198517417920514ecf78d417f91771c`.
- Measured HEAD `0b916376932c8b9633c87dd7145eea18a6e7e8e4`; P31 consumer blob `d19405f2ef0f8d7159978174c1a919ed6d66764f`; original owned-task blob `e74d6a73f956c562eab176e27687a47249f5815d`; M0 pool blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- Generated P34 copy SHA-256 `b035f268cd2114c85d5bf174a950854148212cdb29a6dabaf7b1fb46118ea65c`.
- Native XPS Intel i7-9750H; LDC 1.41.0 / DMD frontend 2.111.0, LLVM 19.1.7; DUB 1.40.0; Ubuntu Linux 6.17.0-22; `powersave`. CPU0 snapshot start/end 4,100,023/3,899,737 kHz; **not** continuous frequency or thermal control.
- Git worktree had unrelated untracked benchmark data, as documented in the archive. Source hashes verify tested tracked inputs but do not prove full environmental isolation.

## Dataset and acceptance

Three sessions; each arm (original P31, generated P34 null, generated P34 timed) has 324 records/session, including 81 warm-up and 243 measured records/session; **729 measured rows/arm** across all sessions, 27 cells × 27 measured rounds. All three analyzer receipts `P34_THREE_ARM_VALIDATED rounds=9 diagnostic_only=true`, and all null/timed receipts `P34_MATCHED_NULL_TIMED_PASS rounds=9`. Same accepted, completed, executed and checksum obligations for every matched profile. Total 8,192 accepted tasks, four workers, ingress 128, retention 1,024; producers 1/2/4, three kinds of work, three ownership modes.

## Median submission interval, minimal work

**Milliseconds; pooled median of 27 measured rounds/arm, not a paired-ratio estimate.**

| Owner | Producers | original | null | timed |
|---|---:|---:|---:|---:|
| M0 | 1 | 17.947 | 17.776 | 18.989 |
| M0 | 2 | 34.141 | 36.752 | 34.389 |
| M0 | 4 | 41.081 | 40.129 | 41.338 |
| Deferred | 1 | 18.623 | 17.835 | 19.950 |
| Deferred | 2 | 32.731 | 35.462 | 38.139 |
| Deferred | 4 | 41.207 | 41.440 | 42.356 |
| Managed P29 | 1 | 19.270 | 19.076 | 20.306 |
| Managed P29 | 2 | 34.778 | 39.764 | 37.623 |
| Managed P29 | 4 | 39.852 | 42.360 | 44.457 |

Shared and sharded two-atomic task variants display the same broad rise in submission time with multiple producers; their data remain in the native archive.

## Allocation and failed admission evidence

`GC.allocatedInCurrentThread` summed producer allocation is roughly 3.24 MB/8,192 accepted tasks for all three ownership arms and all work kinds. Overall medians for original/null/timed are 3,243,328 / 3,243,344 / 3,243,344 bytes. This is **allocated bytes**, not live heap retention, exact allocator event count or per-node cost. The unchanged owner code has three distinct source-level `new` expressions for a successful submission within its mutex, plus potential array-backing changes; this does not imply exactly three allocator calls.

Measured rows with at least one admission retry: original **10/729** (max 41 extra attempts), null **6/729** (max 49), timed **2/729** (max 6). All 27 cell-level median retry counts are zero in each arm. Admission rejection alone does not explain the multiple-producer scaling decline.

For illustration, the median probe duration per *submission attempt* for minimal managed work in the timed copy was approximately 2.34 µs (1p), 8.26 µs (2p), 19.72 µs (4p). These are sums of producer-local timed wrapper intervals divided by attempt counts. They include task/result allocation, owner/manager locks, inbox and scheduling effects. **They are not independent mutex-wait measurements.** Do not directly subtract aggregate concurrent producer durations from elapsed wall time.

## Interpretation and next study

The 1→2→4 producer increase is present in **untouched P31**, null and timed variants: it is not created solely by the added P34 wrapper clocks. Clock overhead and scheduler perturbation nevertheless vary by workload; ratios are neither a constant nor a causal estimate. There is no proof that P29's manager lock, the owned executor lock, GC allocator, or the M0 inbox lock individually dominates.

Next experiment: build an exactly pinned generated P23 owned-task copy with **bounded per-thread counters** or lower-intrusion sample controls for successful allocation/retention and executor-mutex acquisition, with full source and task lifetime parity. Because `trySubmit` is templated and worker callbacks run concurrently, instrumentation must cover rejected/admitted return paths and require explicit join/roots proof. Run DMD and LDC correctness before native XPS measurement; only compare within identical owner/work dimensions. Do not modify production `source/`.

Status: Issue #17 OPEN, ADR-0001 PROPOSED, PR #38 Draft.
