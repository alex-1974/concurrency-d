# M0 Dell XPS — 256-sample idle/wake follow-up (2026-10-12)

**Decision:** the previously suspected 4-worker **p95 wake regression is not reproduced**. The fix remains a **draft production candidate**, not an automatically qualified throughput/latency improvement or a merged change.

## Immutable input and environment

Uploaded `m0-xps-victim-wake-followup.tar.gz` SHA-256 `cb16f5458fd14eb5d5374c2df33642ed38b1424e8a6f1294c173b375f936d61c`. Four files: `environment.txt`, `idle.csv`, `pairs.csv`, `summary.csv`. Data generated with the shared validation harness, source SHA-256 `e031888b299b2b3590a7ec05c42b38aeb58cee1bf8c0f83fab84cbba5b8eb9b8`, validation branch at `301fef61192920c68790f100e23c3bba9ba039ac`.

- **M0 `develop` baseline:** `822a866d866dbb176f5435a41b09d189b8d0c4cb`.
- **M0 full foreign-victim coverage, Draft PR #37:** `31f97b8315980b4b52a97cb1706a507a1422eaa5`.
- LDC 1.41.0 / LLVM 19.1.7, Intel i7-9750H XPS, Linux 6.17.0-22-generic x86-64, DUB 1.40.0; governor `powersave`; one CPU-scaling snapshot at 57%. This is not a controlled CPU-clock or thermal trace.
- `--idle-only`, 20 paired rounds, 1/4/8 workers, **256 sequential wake tasks per run**, 300 ms quiet interval, 1 ms gap, 25 ms cooldown, no concurrently measured throughput tasks.
- 120 idle cases = 60 exact factor/round pairs, **30,720 completed wake tasks**. The checksum is identical in all cases. Per-case result latency order `p50 <= p95 <= p99 <= max`, process idle-wall consistency, pair deltas and ratios reconcile exactly, every required key occurs once, all task counts 256/256.

A prior native M0 run with the same baseline and candidate but **64** wake samples is documented in [the 2026-10-11 review](m0-xps-victim-coverage-review-2026-10-11.md). That earlier 4-worker sample showed slower fix p95 and p99 in 5/5 pairs (paired median deltas +12.49 µs and +19.31 µs); unlike this 256-sample follow-up, it also included a separate 100k-task throughput matrix and measured substantially lower absolute latency. **These campaigns must not be pooled as if they were identical sampling conditions.**

## Native result: medians and matched differences

Figures below are **per-run** nearest-rank latency metrics. `baseline` and `fix` columns are separate medians over 20 runs. `paired Δ` is the median of the 20 within-round fix-minus-baseline differences: it need not equal the subtraction of the two displayed medians. Positive Δ means slower/higher latency or CPU for the fix.

| Workers | Metric | Baseline median | Fix median | Paired Δ median | Fix higher / 20 |
|---:|---|---:|---:|---:|---:|
| 1 | Idle process CPU / 300ms | 129 µs | 126 µs | −3 µs | 8 |
| 1 | Wake p50 | 24.70 µs | 32.90 µs | +1.51 µs | 13 |
| 1 | Wake p95 | 504.36 µs | 510.28 µs | **−0.45 µs** | 10 |
| 1 | Wake p99 | 1,226.08 µs | 1,183.74 µs | −274.19 µs | 8 |
| **4** | **Idle process CPU / 300ms** | **221.5 µs** | **228.5 µs** | **0 µs** | **9** |
| **4** | **Wake p50** | **38.19 µs** | **37.68 µs** | **−1.56 µs** | **7** |
| **4** | **Wake p95** | **552.56 µs** | **475.57 µs** | **−22.50 µs** | **6** |
| **4** | **Wake p99** | **1,304.37 µs** | **1,262.28 µs** | **+133.61 µs** | **13** |
| 8 | Idle process CPU / 300ms | 289 µs | 270 µs | −2.5 µs | 9 |
| 8 | Wake p50 | 39.49 µs | 38.59 µs | −0.18 µs | 10 |
| 8 | Wake p95 | 598.00 µs | 537.22 µs | −22.85 µs | 10 |
| 8 | Wake p99 | 1,165.92 µs | 1,214.14 µs | +77.61 µs | 11 |

Four workers, p95: fix **lower in 14/20 pairs**, higher in 6/20. The earlier 5/5 p95 penalty does **not** reproduce. Four workers, p99: fix higher in 13/20, lower in seven; the baseline/fix independent medians nonetheless favor fix slightly. This is not a stable tail direction. Even a basic unadjusted two-sided exact sign check for 4-worker p95 gives p≈0.115 and for p99 p≈0.263; these are exploratory (many endpoints, uncontrolled runtime/CPU factors), not proof of equivalence.

Idle CPU for four workers is effectively unchanged: paired median **0 µs** of process CPU in 300ms, higher in 9, lower in 9, tied in two. Whole-process idle CPU is not worker-specific CPU or power usage; all sampled absolute values are extremely small. Control cases at 1 and 8 workers show similarly mixed tail directions.

### Crucial measurement limitation

The absolute p95 on **both** M0 implementations is about **0.5 ms** in this run, compared with only approximately **0.05–0.07 ms** at four workers in the prior 64-event campaign. Their p99 values now exceed **1 ms**. The sample count increased from 64 to 256, and host clock/OS activity can differ. The probe polls the shared completion flag using `Thread.yield()` while the task transitions from sleep to execution, so it measures end-to-end submit-to-visible-result under scheduler interference — **not a pure condition-variable wake latency**.

At 256 observations, nearest-rank p99 is the **third-largest** response, not the maximum; `environment.txt` still contains a stale statement that “p99 of 64 samples is maximum.” The raw per-task latency distribution is **not retained**, only p50/p95/p99/max per 256-task child; a pooled 15,360-event statistical p99 cannot be reconstructed. The new report uses only matched per-run summaries.

The submitted repository checkout has numerous **untracked benchmark binaries/research files** (shown in `environment.txt`). The runner nevertheless pins both exact source commits into separate, temporary detached worktrees and confirms an identical benchmark source digest and resolved dependencies; the untracked files must **not** be deleted automatically.

## Engineering interpretation and release gate

- **Resolved as a blocker:** the **specific claim of a reproducible 4-worker p95 wake regression** from five short runs is unsupported by this stronger 20-round native follow-up. Do not preserve it as an established causal effect of the full-victim fix.
- **Not established:** equal wake-tail distributions, general scheduler fairness, absence of all throughput overhead, improved 256-sample p99, universal latency SLOs, or power savings. The 4-worker p99 and wider case-to-case distribution remain noisy.
- **Other evidence still matters:** [the original 100k-task M0 direct report](m0-xps-victim-coverage-review-2026-10-11.md) showed overall fix/baseline median paired throughput ~0.9868×, 34/80 favorable, with selected 4-producer workloads slower. The 256-sample `--idle-only` follow-up **does not rerun throughput** and therefore does not erase that observation. One-worker no-steal control was also noisy.
- **Source-correctness evidence:** PR #37 deterministic all-victim coverage and multi-worker exactly-once tests, plus DMD 2.111 / LDC 1.41 x86-64 and native ARM64 consumer gates, previously PASS. Isolated R0.5 native blocking research independently supports the missed-foreign-victim mechanism, but is not directly comparable to this M0 runtime's throughput.

**Disposition:** recommend technical review of the narrowly scoped complete foreign-victim fix and its plausible small throughput trade-off. No justification for adding the experimental rotating policy. Keep PR #37 **Draft and unmerged until the maintainers explicitly accept the performance/correctness trade-off**; do not silently merge or modify `develop`/PR #35/other repositories from this follow-up. A representative longer steady-state 4-producer test under recorded CPU affinity/frequency/thermal conditions is advisable for strict performance acceptance.
