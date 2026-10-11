# M0 XPS — pinned develop vs full-victim fix, native 100k-task comparison

**Date:** 2026-10-11. **Decision:** **HOLD Draft PR #37** pending targeted 4-worker wake-latency replication; do not claim a speedup.

## Exact evidence and fairness of comparison

Immutable user archive `m0-xps-victim-coverage.tar.gz` SHA-256
`7dd1c6f7b42fd86c037d9b868c6861491be0577e0d725f0ba708698feb5c6bc8`.

- Baseline M0 `develop`: `822a866d866dbb176f5435a41b09d189b8d0c4cb`.
- Candidate M0 PR #37: `31f97b8315980b4b52a97cb1706a507a1422eaa5`.
- Validation harness commit as measured: `d038ff59cb257f56a60479532eb28d4f978036d6`.
- Identical benchmark source SHA-256: `e031888b299b2b3590a7ec05c42b38aeb58cee1bf8c0f83fab84cbba5b8eb9b8`.
- Dell XPS Intel i7-9750H 6C/12T, Linux 6.17.0-22, LDC 1.41.0/LLVM 19.1.7 release, DUB 1.40.0. CPU governor **powersave**, one `lscpu` CPU-scaling snapshot 92%, no fixed affinity/frequency/thermal trace.

Same borrowed-TaskRef M0 semantics, container queue, batches, DUB dependencies and injected benchmark code in both detached temporary worktrees. These measurements are **not** comparisons to the separate R0.5 OwnedTask executor.

Five paired rounds × worker counts 1/2/4/8 × producers 1/4 × minimal/compute × 2 versions = **160 mixed runs**, 100k tasks each, **16 million executed tasks**. Five rounds × 1/2/4/8 workers × two versions = **40 idle/wake cases**, 64 tasks each, **2,560 wake task results**. All 80 mixed and 20 idle factor/round pair keys are unique, accepted/completed counts and deterministic checksums match between baseline/fix, task results are exactly once, and all schema/timing sanity checks pass. The archive includes `mixed.csv`, `idle.csv`, `pairs.csv`, `summary.csv` and `environment.txt`.

## Mixed throughput (fix/baseline), matched per-round medians

All figures are **medians of five same-round elapsed-baseline/elapsed-fix ratios** at identical 100k tasks, not ratios of independent medians. Below 1.0 indicates the fix was slower.

| Workers | Producers | Minimal | Compute |
|---:|---:|---:|---:|
| 1 | 1 | 0.943× (2/5 favorable) | 0.998× (1/5) |
| 1 | 4 | 0.992× (2/5) | 1.084× (3/5) |
| 2 | 1 | 0.969× (1/5) | 1.009× (3/5) |
| 2 | 4 | 1.145× (3/5) | 0.935× (1/5) |
| 4 | 1 | 0.935× (2/5) | 1.042× (3/5) |
| **4** | **4** | **0.953× (2/5)** | **0.979× (1/5)** |
| 8 | 1 | 1.057× (4/5) | 0.969× (2/5) |
| 8 | 4 | 0.985× (2/5) | 0.984× (2/5) |

Pooled descriptive median across 80 throughput pairs **0.9868×**; fix faster in **34/80**. Compute-only median **0.9815×**, fix faster **16/40**. With 4 workers/4 producers and compute, fix is slower in **4/5**. With 2 workers/4 producers/compute, fix is also slower in **4/5**.

**Noise and confounding:** one-worker control (no stealing possible) still shows large fluctuations, e.g. one worker / four producers / minimal pairs span **0.475–1.377×**. No controlled CPU-frequency, GC-load, thermal or affinity evidence. Do not infer that the victim-sweep loop itself causes every measured ratio. The 1024-round synthetic compute kernel is not a substitute for representative consumers. This is not a statistically justified no-overhead conclusion.

## Idle CPU / wake response

The idle probe measures process CPU during 300ms after constructing the pool; then it submits one task at a time and **polls its result with Thread.yield**. These numbers are therefore whole-system observable **submit-to-completion** response for this particular test method, not a pure condition-variable wake latency or real-time SLA.

| Workers | Idle CPU baseline→fix (µs) | p95 baseline→fix (µs) | p99 baseline→fix (µs) |
|---:|---:|---:|---:|
| 1 | 90 → 88 | 58.0 → 53.0 | 77.4 → 75.5 |
| 2 | 205 → 163 | 57.0 → 54.3 | 74.7 → 66.4 |
| **4** | **402 → 273** | **52.8 → 65.3** | **67.4 → 91.5** |
| 8 | 266 → 176 | 56.2 → 52.1 | 83.3 → 68.1 |

At **four workers**, paired median p50 delta **+3.20µs**, p95 **+12.49µs**, p99 **+19.31µs**. Each is *higher in all five matched rounds* for the fix. p95 individual deltas range +6.36 to +15.54µs; p99 range +7.31 to +30.39µs. The 4-worker paired median idle CPU delta is **−186µs** (two of five higher); no evidence of persistent spin.

With only 64 observations, the reported nearest-rank **p99 is the largest observed wake** of its run. Its numerical value is not a reliable long-term p99 percentile. Five consistent 4-worker p95 signs merit replication, but do not alone establish an algorithmic root cause.

## Merge decision and isolated next gate

- **KEEP Draft PR #37 unmerged.** Its tiny full-foreign-victim-coverage fix has a clear deterministic bug rationale and passing DMD/LDC x86/native ARM64 regression tests, but direct M0 native resource evidence identifies a possible 4-worker wake response penalty and mixed-workload slowdown.
- **DO NOT** cherry-pick PR #35 wholesale, promote experimental rotation or modify defaults. Research PR #35 and Issue #20 remain preserved.
- Reproduce 4-worker idle/wake at **20 paired rounds × 256 wake tasks per variant**, with 1/8-worker controls and no concurrent mixed matrix. The validation harness now offers `--idle-only` and the x86/ARM64 CI tests cover that option ([protocol](../m0-full-victim-coverage-xps.md)).
- Investigate `Thread.yield` perturbation, CPU governor/frequency, process noise, and potential extra unsuccessful steal before declaring a scheduler regression or merge.

Native follow-up, from `validation/m0-victim-coverage-xps`:

```bash
python3 tools/validation/m0_victim_coverage_xps.py \
  --compiler=ldc2 --idle-only --rounds=20 \
  --workers 1 4 8 --producers 1 --workloads minimal \
  --tasks=2048 --budget=512 \
  --idle-ms=300 --wake-samples=256 --gap-ms=1 \
  --cooldown-ms=25 \
  --output=evidence/m0-xps-victim-wake-followup

tar -czf m0-xps-victim-wake-followup.tar.gz \
  -C evidence m0-xps-victim-wake-followup
```

The first two pinned commit SHAs remain **exactly** those used for this study. Neither the production fix branch nor `develop` is modified by validation.
