# P30 XPS evidence — 2026-10-15 (exploratory; preserve original)

**Status: KEEP research evidence; no performance-based production decision.**
[Full protocol](../README.md) · [P29 owner safety](../../p29_generational_owner/README.md)
· [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Immutable provenance

The user provided `concurrency-p30-xps-20261015T134105Z.tar.gz`
and accompanying SHA-256 receipt. Independently verified
archive SHA-256: `2252c2b81b7d5894578dd3dc82158c2a83763f78a592a4f17b6a2bb1af9b14c3`.

Measurement commit: `33d4e17b088460bd0489688af6482eb2d560ae9b`;
unchanged M0 owner Git blob `e74d6a73f956c562eab176e27687a47249f5815d`,
native pool blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
Machine: Dell XPS 15, Intel Core i7-9750H, 6 physical / 12 logical
cores, LDC 1.41.0 / LLVM 19.1.7, DMD frontend 2.111.0,
DUB 1.40.0, Linux x86_64.
Build: optimized DUB `release`, `p29-generational-optimized`,
`P30Benchmark` (`-O3`).
CPU frequency governor: `powersave`; only start/end CPU0
frequency snapshots (~4.10/4.13 GHz), not a thermal trace.

The archive contains three profile CSVs, all raw execution logs,
three emitted JSON summaries and metadata. 3 warm-up plus 9 measured
triplets/profile = **108 CSV records, 81 measured records**. Every
record meets `accepted == completed == count`,
`checksum == count * 60` and `attempts >= count`.
The external archive is the evidence source; do not silently replace,
rename or retroactively normalize its results. Hostname, absolute
personal paths and unrelated untracked local files from the original
metadata are deliberately not repeated here.

## Nine-round medians (submit interval only)

The three arms are `m0` original, `deferred` original P23
source-pinned owner, and `managed` actual P29 manager. The
work function, worker implementation, and per-profile capacity are
matched. The original M0 has a weaker lifetime guarantee and is an
implementation baseline, **not a semantic replacement** for P29.

| Producers | Workers | Tasks | M0 (ms) | Deferred (ms) | Managed (ms) | Median paired Managed/Deferred | Median paired Managed/M0 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 2 | 8,192 | 9.079 | 9.805 | 9.421 | 0.834 | 1.041 |
| 2 | 2 | 8,192 | 16.440 | 17.286 | 17.262 | 1.006 | 1.042 |
| 4 | 4 | 16,384 | 70.704 | 73.101 | 73.489 | 1.034 | 1.071 |

A **paired ratio median** is the median of the nine ratios
computed *within corresponding measured round*, not the ratio
of the displayed separate medians.

| Producers | Managed/Deferred per-round ratio range | Slower in | Deferred/M0 ratio median |
|---:|---:|---:|---:|
| 1 | 0.469–1.051 | 3/9 | 1.152 |
| 2 | 0.712–1.074 | 5/9 | 1.026 |
| 4 | 0.878–1.243 | 5/9 | 1.087 |

Managed overhead is **not resolved** by this sample: in both
multi-producer profiles, only 5 of 9 paired directions favor Deferred.
The unusual apparent managed speedup for one producer is largely
associated with Deferred outliers (up to ~20 ms) and **does not**
prove adding a Mutex improves speed.

M0 throughput under these *profiles* falls from roughly
0.902 to 0.498 to 0.232 million tasks/s as producers increase
from one to two to four. Four producers also have four workers
and twice the task count; this is **not a strict producer-only
scaling experiment**. The repeated decline is larger than the
unresolved P29/Deferred difference and warrants controlled
mechanism research. Work function increments **two shared atomic
counters**, and the original submission and retention paths
also use synchronization and allocations; these potential sources
are **not individually separated** by P30.

Producer-thread cumulative GC allocations are almost identical
across all arms, approximately **412 bytes per accepted task**.
This metric is NOT total process RSS, peak GC heap, scheduler-thread
allocation or retained owner footprint. Startup and join times
are tens to low hundreds of microseconds, below the main
submission time for these profiles; startup cross-arm
differences vary by workload and are not a stable verdict.

## Newly discovered positional order bias

The original benchmark uses these arm orders:
`M0→Deferred→Managed`,
`Managed→Deferred→M0`,
`Deferred→M0→Managed`.
Across nine measured triplets M0 is placed evenly (3× per
position), **Deferred is never third** (3× first, 6× second),
and **Managed is never second** (3× first, 6× third).
This is an unnecessary, potentially confounding imbalance.

**Correction for FUTURE runs only:** the P30 source was updated
after this measurement to a cyclic Latin square with each
arm once at each position:
`M0→Deferred→Managed`,
`Deferred→Managed→M0`,
`Managed→M0→Deferred`.
An always-evaluated source check rejects non-balanced orders.
The original archive remains pinned to the uncorrected source
commit above. A new native measurement is necessary before
comparing balanced-run ratios.

## Disposition / next controlled measurement

**KEEP** P29 generations, explicit native join-before-release
and independent GC roots. **NO-GO** on removing manager locks
or promoting a public API based on one noisy XPS sample.

1. Repeat the three profiles with the corrected order; preserve
   all raw CSV/metadata, ideally in several separated measurements.
2. Qualify producer scaling with the **same count, workers, ingress
   and retention budget** for producer counts 1/2/4; measure
   CPU frequency/thermals and unrelated process load where possible.
3. Distinguish M0 admission lock/retention cost from test-job
   shared atomic overhead and manager submission validation,
   without weakening any ownership semantics.
4. Only if the P29 manager cost remains material, research
   a generation-checked lifetime lease **per batch** with
   equivalent native-join and root safety; benchmark in
   optimized configurations before deciding.
5. No C++ parity claim is supported: no semantically equivalent
   C++ comparator appears in this evidence.

This remains grandfathered research only. PR #38 Draft,
Issue #17 OPEN, ADR-0001 PROPOSED. Do not promote to
`source/`, `develop` or `main`; PR #35 untouched.
