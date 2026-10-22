# M0 public-path performance qualification

**Result:** protocol v1.2 passed for the scoped host/compiler/workload claim below. This is not a general performance guarantee and does not authorize a release.

## Scope and method

The candidate was measured at HEAD `414d864fcd0bf9df910d96fe9985d04b576d25db`, binary SHA-256 `3c62a451c2752f92926368db3c27d82767764c503a5a85e35c2cf0cdfbf1b367`, with LDC 1.42.0 on Ubuntu 26.10 / Linux 6.17.0-22-generic, Dell XPS 15, Intel Core i7-9750H (6 cores / 12 logical CPUs). The claim covers only this machine/compiler combination and the two checked-in CPU kernels.

The independent sample used 20 cooled sessions per stratum, four paired public/internal runs per session, and matching checksums: 80 pairs per stratum, 320 pairs total. The statistic was the median of four paired ratios per session. The one-sided upper bound was the nearest-rank 98.75th percentile from 100,000 session-cluster bootstrap replicates (seed `20261022`). Pass required all four bounds ≤1.10.

| Kernel | Scenario | Median of session medians | 98.75% upper bound | Result |
|---|---:|---:|---:|---|
| 131,072 tasks × 128 iterations | 1P/1W | 1.0082 | 1.0134 | Pass |
| 131,072 tasks × 128 iterations | 4P/4W | 0.9979 | 1.0076 | Pass |
| 16,384 tasks × 2,048 iterations | 1P/1W | 1.0126 | 1.0922 | Pass |
| 16,384 tasks × 2,048 iterations | 4P/4W | 1.0146 | 1.0326 | Pass |

During the run, the firmware profile remained `cool`, `fancontrol` was inactive, maximum sampled package temperature was 74 °C, minimum fan readings were 2,245/2,237 RPM, and CPU0 package/core throttle counters stayed at 1393/243. The earlier, separate 10-session sample missed the long-kernel 1P/1W bound at 1.1046; it was not pooled with this independent sample.

## Evidence identity and remaining gates

Full telemetry and arm-level timings are retained with the execution record. SHA-256 identities for the archived files:

- `metadata.json`: `fdb6f395b81a58e3d3e203c68e9bceb10d2b2742bf9e0b1b29cbaf24c911cb55`
- `analysis.json`: `6ce7b2e6a2ff913c1828b810bff2ad3def327539c5840252a438d6e5f85a0277`
- `raw.csv`: `9f52ad61794f7cfe57461a491b4680c0c089a88532c3d628a2ac4899268413a3`
- `telemetry.jsonl`: `b3792a0ca76f8b6343f7a68bc733f03fb598680ef71e63db60d5a482576ea460`

This performance result does not settle the process-fatal native lifecycle policy or public API contract. Both still require maintainer review. Exact-head DMD/LDC/native ARM64 CI and the final version/archive/tag/publication checks also remain part of release acceptance.
