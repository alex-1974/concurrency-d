# P30 native XPS — balanced repeat and paired baseline comparison

**Date:** 2026-10-15. **Status: KEEP as measured research evidence; no production promotion.**
This is the second user-supplied XPS capture and its comparison with the
[original, order-imbalanced XPS evidence](xps-2026-10-15-results.md).
Neither source archive is replaced or retroactively adjusted.

## Archive integrity and provenance

| Capture | Source HEAD | SHA-256 of original tar.gz |
|---|---|---|
| First, order imbalanced (13:41 UTC) | `33d4e17b088460bd0489688af6482eb2d560ae9b` | `2252c2b81b7d5894578dd3dc82158c2a83763f78a592a4f17b6a2bb1af9b14c3` |
| Second, balanced (13:59 UTC) | `eacbe9a1f63d51a873ce1e40ae86e7198cac7557` | `66ef3809b90f8479bf3bb5d2abf7ec438e90d07a7c6bf1e6445067fe57b4acaf` |

Both uploaded archives independently match their own uploaded SHA-256
receipts. Full names: `concurrency-p30-xps-20261015T134105Z.tar.gz`
and `concurrency-p30-xps-20261015T135943Z.tar.gz`.

The source-pinned M0 blobs remain identical in both captures:
`owned_task.d` = `e74d6a73f956c562eab176e27687a47249f5815d`;
`submission_pool.d` = `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

Hardware and toolchain: Dell XPS 15, Intel Core i7-9750H,
6 physical / 12 logical CPUs, Linux x86-64, LDC 1.41.0 / LLVM 19.1.7,
DUB 1.40.0; DUB whole-release with `-O3`,
`--config=p29-generational-optimized --d-version=P30Benchmark`.
Both captures report a `powersave` governor; start/end CPU0
frequency snapshots were approximately 4.10/4.13 GHz (first)
and 4.10/4.00 GHz (second). They **do not** constitute an
affinity, thermal, full frequency or background-load trace.

The original raw CSV, `*.raw`, JSON summaries and metadata
remain in the supplied archives. The research finding intentionally
does not reproduce personal absolute paths or the user's long
untracked-file inventory.

## Correctness and benchmark balancing

Each capture contains three profiles, with three warm-up and nine
measured three-arm triplets per profile: **108 CSV records / archive,
81 measured records**. All **216 records across both captures**
independently satisfy:

- `accepted == completed == count`;
- `checksum == count * 60` and `attempts >= count`;
- positive and internally consistent `MonoTime` phase intervals;
- exactly one of `m0`, `deferred`, `managed` in every triplet;
- identical count, worker/producers, ingress, retained limit, accepted,
  completed and checksum across the three arms in each triplet.

For both runs: one/two producers mean **8,192 Tasks and 2 M0 workers**;
four producers mean **16,384 Tasks and 4 M0 workers**.
Ingress capacity is 64/64/128, retention budget 1,024.

Measured-position audit (per profile, nine triplets):

| Mode | First run positions 1/2/3 | Balanced run positions 1/2/3 |
|---|---:|---:|
| M0 | 3/3/3 | 3/3/3 |
| P23 deferred | 3/6/0 | 3/3/3 |
| P29 managed | 3/0/6 | 3/3/3 |

The second source HEAD qualifies P30's order-balance assertion.
The first source HEAD remains the historical control with the
identified positional bias. Both use the **real unchanged M0
`SubmissionWorkerPool`** and the same typed atomic-checksum task,
not two simulated schedulers.

## Submission interval results

Each ms column below is a median of nine measured intervals
(including producer-thread startup/join and overlapping worker
execution). The ratio is the **median of nine same-round P29/P23
ratios**, not the ratio of the displayed medians.

| Run | Producers | M0 median ms | P23 median ms | P29 median ms | P29/P23 paired median | P29/P23 range | P29 slower |
|---|---:|---:|---:|---:|---:|---:|---:|
| First, biased | 1 | 9.079 | 9.805 | 9.421 | 0.834 (-16.6%) | 0.469–1.051 | 3/9 |
| First, biased | 2 | 16.440 | 17.286 | 17.262 | 1.006 (+0.6%) | 0.712–1.074 | 5/9 |
| First, biased | 4 | 70.704 | 73.101 | 73.489 | 1.034 (+3.4%) | 0.878–1.243 | 5/9 |
| Repeat, balanced | 1 | 9.369 | 9.759 | 9.959 | **1.022 (+2.2%)** | 0.975–1.073 | 6/9 |
| Repeat, balanced | 2 | 17.536 | 18.087 | 18.483 | **1.017 (+1.7%)** | 0.760–1.522 | 5/9 |
| Repeat, balanced | 4 | 69.018 | 74.667 | 75.975 | **1.012 (+1.2%)** | 0.884–1.199 | 5/9 |

Balanced-run paired P29/M0 submit median ratios are
1.071 / 0.873 / 1.076 for 1/2/4 producers; P23/M0 are
1.044 / 1.026 / 1.034 respectively. Notably, the two-producer
**P29/M0 paired median < 1** conflicts with the ordering of
the independent arm medians; cross-arm drift/outliers are a
reason **not** to use a ratio of medians as a substitute for
round-matched differences.

### Startup, join and allocation (balanced repeat)

Median phase values in **microseconds**, not total TaskRef work:

| Producers | M0 startup | P23 startup | P29 startup | M0 join | P23 join | P29 join |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 73.0 | 72.7 | 74.7 | 85.2 | 123.9 | 83.5 |
| 2 | 71.8 | 73.1 | 75.7 | 39.3 | 81.4 | 68.0 |
| 4 | 105.4 | 102.9 | 113.8 | 50.3 | 52.3 | 61.1 |

All arms show approximately **412 producer-thread GC allocation
bytes per successfully accepted TaskRef**. This is not peak
RSS, total process allocation, lifetime-root storage size, or
GC allocations in worker threads. Attempts may differ slightly
due to contention/backpressure; **accepted and executed work
is identical**.

## Interpretation, limitations and next research gate

**KEEP P29 safety semantics.** The balanced repeat produces a
small positive P29/P23 paired submission ratio, but signs
6/9, 5/9 and 5/9 and ranges crossing 1 are not enough to
attribute a stable 1–2% regression to the **manager Mutex**.
The interval also covers M0 admission, task publication,
producer threads, retained GC objects and the benchmark task's
two shared atomic counters. The initial single-producer
apparent P29 speedup is not reproduced after position balance.

**Do not infer pure producer scaling from these three
profiles.** The four-producer case doubles the task count
and changes the worker count, so producer effects, work amount,
worker scheduling and CPU contention are confounded. Large
profile-level throughput differences are a research lead,
not yet a decomposition of M0 bottlenecks.

Nine triplets per profile and two captures on one host,
without a continuous CPU thermal/frequency trace or
external interference control, do not support a release
performance contract or an absolute D-vs-C++ claim. The
original M0 control also has a **weaker independent
ownership/native-error contract** than managed P29.

**Next (P31 research):** fix TaskRef count, worker count,
ingress and retained budget while sweeping 1/2/4 producers;
separate the shared atomic-task cost from admission lock /
GC record-reclamation and instrument bottlenecks with
release-mode LDC, preserving the original M0 source and
P29 native-join-first root release. If a generation-checked
batch lease is explored, require equal lifetime/race
qualification before any speed comparison.

**Disposition:** KEEP both SHA-verified XPS captures and
these negative/positive findings. Do not change production
`source/`, merge PR #38, or modify grandfathered PR #35.
ADR-0001 remains PROPOSED and Issue #17 OPEN.
