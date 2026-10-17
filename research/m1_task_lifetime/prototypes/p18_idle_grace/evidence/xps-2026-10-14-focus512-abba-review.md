# P18 — Focus512 native ABBA Dell-XPS audit (2026-10-14)

**Status: FULL / EXACT-ORACLE PASS / THERMAL ATTENTION / research only.** No production promotion. This is the complete independent audit of the supplied Focus512 XPS archive, NOT a new benchmark or source revision.

## Original evidence, source and completeness

- Original archive `p18-focus512-20261014-110125.tar.gz`, SHA-256 **`df4b1e1f60a0f95d4e7a6523f8af3e390e1138402fa1ab3e0718a77f84a61da6`**. The raw archive stays outside Git because host paths and machine identifiers may be private.
- Manifest HEAD **`0f85b1cbf9e5545c4b32d8752e58814070d0afb6`**, unchanged original production M0 source blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**, LDC **1.41.0 / LLVM 19.1.7**, DUB 1.40.0, x86-64 Dell XPS 15 Intel i7-9750H, release binaries, process CPU affinity `0,1,2,3` (four physical cores), worker threads not individually pinned.
- The two prebuilt whole-release binaries have **different** retained SHA-256 values: control `faa85babc9392cb52bc205e06485568d2d878d56231c38c428ffd7b59d517558`; grace `bf170f657f6aadefde624840d49c556eb5a92cf207bb14e037e7ac1f53a2ec69`. Binary paths are local temporary paths and not checked into Git.
- Four complete sessions, each 4 whole processes: `M0, grace, grace, M0` (sessions 1/3) and `grace, M0, M0, grace` (sessions 2/4); 16 process CSVs and source logs. Every original raw stdout CSV line is byte-equal to its normalized process CSV line. All 16 processes contain exactly **27 configurations × (2 warm-ups + 5 measured) = 189 scenario rows**, 54 warm-up and 135 measured rows.
- Eight correctly matched ABBA adjacent control/grace pairs, totaling **1,080 measured pairs** and 432 warm-up pairs. Exact phase/round/order/seed/worker/task-count/wave-count/iteration/ingress/checksum equality for every corresponding row; all five stage durations nonnegative and sum to `total_ns`. Each setting has 2,048 TaskRefs per wave × 3 waves, workers 1/2/4, ingress 8/64/256, iterations **128 / 512 / 1024**. Native close/producer race preflights completed before measurement. No evidence of a missing or truncated process.

## Uninstrumented P18 / original M0 `waves_ns` ratios

For all tables, numbers are the **median of individually matched ratios**, NOT the ratio of separately calculated medians. A ratio above 1 favors original M0.

| Iterations | 1 worker | 2 workers | 4 workers | All workers (360 matched pairs) | P18 wins |
|---:|---:|---:|---:|---:|---:|
| 128 | 0.9804 | 0.9625 | 0.9148 | **0.9559** | 219/360 |
| **512** | **1.0119** | **1.0179** | **1.0036** | **1.0119** | 166/360 |
| 1024 | 0.9836 | 0.9820 | 0.9812 | **0.9829** | 208/360 |

Full equally weighted synthetic matrix: **1,080 pairs; median 0.9870; 593 P18 wins**. It is not an application-weighted overall throughput or latency benefit. Wavelength timing excludes construction/join/verification. At 512 the median `total_ns` ratio is **1.0058**, also not a complete consumer transaction benchmark.

**512-iteration settings** (40 paired measurements each, pooled over four sessions × two adjacent pairs × five measured rounds):

| Workers | Ingress 8 | Ingress 64 | Ingress 256 |
|---:|---:|---:|---:|
| 1 | 1.0297 | 1.0143 | 0.9980 |
| 2 | 1.0327 | 1.0054 | 1.0162 |
| 4 | **1.1052** | 1.0143 | **0.9532** |

Seven of nine setting medians are above 1. In the 512 group the median P18−M0 producer retries is **−192 per measurement** and median parks **−3**, yet P18 can be slower. These aggregate counts cannot assign a time cost, validate successful foreign-steal behavior, or prove an idle-grace causal effect.

### Session, ABBA half and time sensitivity

| Session | 128 iterations | **512 iterations** | 1024 iterations |
|---:|---:|---:|---:|
| 1 | 0.9690 | **0.9898** | 0.9690 |
| 2 | 0.9050 | **0.9765** | 0.9561 |
| 3 | 0.9428 | **1.0472** | 1.0066 |
| 4 | 1.0350 | **1.0487** | 1.0078 |

The direction at 512 **reverses between sessions 1–2 and 3–4**, despite alternating ABBA/BAAB orders. This rules out a simple unidirectional process-order explanation but does **not** rule out frequency drift, temperature, other load, or scheduler nondeterminism.

Separating **first vs second adjacent half** yields 512 medians: session 1 `1.0004 / 0.9838`; session 2 `1.0010 / 0.9616`; session 3 `1.0375 / 1.0513`; session 4 `1.0367 / 1.0512`. Thus both halves show a median 512 regression in sessions 3/4, and one affected thermal trace cannot explain the entire observed direction.

As an additional **non-decisive paired diagnostic**, within each identical session/ABBA-half/worker/ingress/round the median `R512 / sqrt(R128 * R1024)` is **1.0472** (where `Rk` = P18/M0 timing ratio at k iterations). Per-session medians **1.0409 / 1.0472 / 1.0744 / 1.0279**, all above 1. Separate workloads do not run at exactly the same instant; this **is not valid automatic normalization** or a proof that one extra search consumes 4.7% of time. It shows a comparatively poorer 512 response than both adjacent work sizes within the measured matrix.

Collapsing each ABBA block to the geometric mean of its two adjacent matched ratios (one per process-order position) yields **180 observations per task size** and pooled medians: **128 → 0.9548; 512 → 1.0230; 1024 → 0.9871**. These are **not independent samples** from different host sessions (only four sessions); show the aggregation explicitly rather than silently treating 360 case/half ratios as independent experiments.

## Thermal observations and sensitivity

Sixteen process thermal traces were sampled nominally every 500 ms (4–5 data rows each). **One process is flagged**: `session3-grace1.csv` sampled **93–95 °C** and an increase of **+36** in the package-throttle count as reported per selected CPU. These are replicated package counters across CPUs; **do not sum them as independent events**. Fifteen remaining processes show no observed counter increase. Sampled `scaling_cur_freq` ranges are not per-worker calibrated execution clocks; missing within-interval events remain possible.

At **512 iterations**, deleting the **45 measured pairs** that involve the flagged `session3-grace1` process gives a median P18/M0 ratio of **1.0108** across the remaining **315** pairs (all pairs median **1.0119**). The later `session3-grace2` process (unflagged) also has median **1.0513** at 512 iterations. Therefore the single flagged run is **not the sole contributor** to the observed unfavorable 512 result; however this deletion does not retroactively qualify the full run or remove possible system-state confounding. Excluding **all of session 3** instead gives **0.9998** (270 pairs): the strength and direction of this small effect depend on session selection, and must **not** be described as a deterministic 512 slowdown.

Observed package temperatures across 16 processes are approximately **75–95 °C**, with different temperatures even inside an ABBA group. Temperature is an **attention flag**, not a reason to discard all data or to claim an isothermal proof. The high 95 °C sample and actual throttle-counter increase require explicit annotation in any performance verdict.

## Decision and next evidence

**KEEP as narrow P18 short/bursty-work research, DEFER an unconditional general scheduler default.** P18 is favored at 128 and 1024 iterations in this corpus, but shows a recurring **workload-specific relative penalty near 512** against both controls and modest, session-sensitive absolute 512 regressions. Reduced parks/retries do not establish the mechanism. The uninstrumented ABBA measurements are complete, but there is one observed thermal-throttle counter increment; no CPU energy/idle transient or realistic GUI workload has been measured here.

**Next bounded experiment, if pursued:** *separately instrumented event-only* M0 and P18 copies from the exact pinned source. Count each worker's first/second failed search, successful local/inbox/foreign work after grace, steal attempts/successes, park attempts and actual waits (including outstanding accepted work vs idle). Use same 512/128/1024 TaskRef corpus for event distributions and conservation, and **never rank instrumented arm timings against the uninstrumented ABBA speed result**. Include native join/close races and DMD/LDC smoke before interpreting events. No general adaptive policy without causal evidence.

Production `source/`, `develop`, grandfathered R0.5 PR #35, ADR-0001 PROPOSED, Issue #17 OPEN and Draft PR #38 remain unchanged.
