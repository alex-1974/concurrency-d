# P18 — Dell XPS balanced 1/2/4-core process-affinity ABBA review (2026-10-14)

**Research only. KEEP narrowly scoped P18; DEFER unconditional production promotion.** Independently audited **uninstrumented whole-release** source-pinned M0 versus P18. CPU-mask intervention changes concurrent physical-core capacity and other OS/cache/clock effects together; it does **not** independently time an instruction, lock, condition wakeup or runnable delay.

## Artifact and provenance

- Original archive `p18-affinity-20261014-205838.tar.gz`, independently calculated SHA-256 **`5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`**; raw host-bearing archive retained outside Git.
- Experiment exact source HEAD `1a8b0eab30f8f7a46057f22b8cbead23375e7683`; production M0 pool blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. P13 TaskRef kernel / producer / driver and bounded-idle-search P18 remain unchanged.
- LDC 1.41.0 (frontend DMD 2.111, LLVM 19.1.7), release, DUB 1.40.0, Dell XPS 15 i7-9750H, Ubuntu kernel 6.17.0-22. Two prebuilt uninstrumented arm binaries, reused across **all** CPU masks: M0 SHA-256 `e3ede1cf0d635acbd575ddfaf52c2971aadff2c7e7a8374270bda349a7cea2bf`; P18 `0a93702e795f7f0cc42ee1159078d17e12dbe9189132afa4cf8c757767ad28dd`.
- Process-affinity masks `{0}`, `{0,1}`, `{0,1,2,3}`; original runner verifies requested/effective masks and distinct physical cores before proceeding. The archive retains the successful collector manifest but not independent raw sysfs topology snapshot or native race-preflight stdout. The runner requires native close/producer race preflights at one and four CPUs, but individual preflight outputs cannot be independently re-audited from the archive.
- Six completed sessions with **all six permutations** of the three CPU-mask block orders; arm orders ABBA/BAAB alternated. **72/72 whole processes**, each 12 cases × (2 warmups + 5 measured) = 84 case records. Independent exact raw-to-CSV line comparison **PASS all 72**, **6,048 scenario rows**; **2,160/2,160 exact-work measured pairs**, **864/864 warmup pairs**. Seed/shuffle/workcount/waves/iteration/ingress/checksum and stage-time conservation PASS for every row. Iteration checksums 128=`13265944963623`, 512=`13257374174144`, 1024=`13299708084730`, identical across CPU masks. Full-inbox retries at capacity 2048 exactly zero across every arm/process/round.

## Principal finding: one-core affinity reverses the 512 regression

`R = P18.waves_ns / M0.waves_ns`; values below 1 favor P18. Each cell is the median of **60 individually matched native measured ratios** (six sessions × two ABBA halves × five measured rounds); they do not represent sixty independent XPS hosts.

| Iterations=512, ingress | 1 CPU | 2 CPUs | 4 CPUs |
|---:|---:|---:|---:|
| 8 | **0.121511** | 1.044167 | 1.036506 |
| 64 | **0.123986** | 1.036241 | 1.040271 |
| 256 | **0.218638** | 1.040959 | 1.034855 |
| 2048 | **0.798020** | 0.986253 | 0.995324 |

The dramatic **one-core advantage is not unique to 512 work**. With ingress 8, at iterations 128/512/1024, one-core median ratios are **0.062713 / 0.121511 / 0.186655**; two cores **0.981122 / 1.044167 / 0.997025**; four cores **0.958478 / 1.036506 / 0.993330**. With two/four cores, the historical narrow 512 penalty persists at bounded ingress and is absent or close to parity when producer-full retries are prevented by ingress=2048.

At **512 iterations**, the source-locked measured per-arm median wave timings and event counters show why the one-core workload behaves differently:

| Cores | Ingress | M0 waves (ms) | P18 waves (ms) | M0/P18 actual parks | M0/P18 full retries |
|---:|---:|---:|---:|---:|---:|
| 1 | 8 | 57.907 | 6.704 | **5899 / 0** | 35 / 765 |
| 1 | 64 | 41.998 | 5.102 | **4262.5 / 0** | 30 / 93 |
| 1 | 256 | 22.967 | 4.955 | **2067 / 1** | 15 / 21 |
| 1 | 2048 | 6.576 | 4.835 | 163.5 / 0 | 0 / 0 |
| 2 | 8 | 5.437 | 5.668 | **3 / 0** | 6171.5 / 5917.5 |
| 2 | 64 | 5.471 | 5.630 | **3 / 0** | 5980 / 5772.5 |
| 2 | 256 | 5.404 | 5.639 | **3 / 0** | 5380.5 / 5174 |
| 2 | 2048 | 5.119 | 5.051 | 3 / 0 | 0 / 0 |
| 4 | 8 | 5.523 | 5.749 | **3 / 0** | 6173.5 / 5958.5 |
| 4 | 64 | 5.550 | 5.784 | **3 / 0** | 5993 / 5773 |
| 4 | 256 | 5.505 | 5.666 | **3 / 0** | 5386.5 / 5177 |
| 4 | 2048 | 5.183 | 5.175 | 3 / 0 | 0 / 0 |

**Caution:** `park_count` counts real original `Condition.wait` entries, not duration. The enormous one-core M0 parking count **correlates** with its much longer native wave time but does not prove a per-park cost. At one core, P18 can have *more full producer retries and yet much faster execution*, ruling out raw full-retry counts as a sufficient time model. No kernel scheduling timeline or runnable-delay observation was made. The one-core speed ratio is for `waves_ns` on a specific research consumer, **not whole-application speedup or energy**.

## Reproducibility and thermal exceptions

- One-core, 512, ingress 8 within-session ratio medians: **0.15030, 0.10976, 0.11621, 0.11589, 0.11704, 0.12656**. Every one of six sessions favors P18. At ingress 64/256 the same qualitative result holds in all six sessions.
- Four-core 512 ingress 8 session medians: **1.03241, 1.12494, 1.02969, 1.01996, 1.02902, 1.02389**: all six favor M0. Two-core 512 ingress 8 has mixed sessions: **1.04203, 1.08405, 0.88755, 1.06196, 1.03909, 1.06097**; pooled 1.044167 is not an every-session claim.
- Geometric mean of the two adjacent A/B halves *before* median (30 collapsed ratios/cell) retains directions: CPU1/512 ingress 8 **0.117755**, ingress 64 **0.122512**, ingress 256 **0.219321**, ingress 2048 **0.758165**; CPU4 ingress 8 **1.038132**, ingress 64 **1.040532**, ingress 256 **1.046701**, ingress 2048 **1.005853**. Absolute paired ratios remain the primary performance result.
- Exactly two thermal traces, both original-M0 **one-core session 6** processes, sample a package maximum of **97 °C** and are flagged `HIGH_SAMPLE`; no observed package-throttling counter increase. **Dropping all session 6** changes one-core 512/ingress-8 median from **0.121511 to 0.11983**: result does not depend on these hot processes. Other observed package temperatures reached 54 °C. Asynchronous nominal-500 ms thermal/frequency samples cannot prove uninterrupted clocks, transient throttle absence or energy.

## Interpretation and bounded decision

One-core affinity makes M0 repeatedly park on the generation-guarded Condition path (roughly thousands of waits per task-wave measurement), while P18's existing bounded worker idle-grace path usually avoids the waits. With two/four physical cores, M0 typically parks only three times and P18's slight 512 bounded-ingress overhead remains. This is **strong reproducible evidence of a CPU-availability × bounded-ingress × parking interaction**, not proof of wakeup latency, intrinsic `Thread.yield()` or mutex hold time. Process masks also modify CPU concurrency, potential turbo, cache placement and OS migration. Even at one core ingress 2048, zero full-retries do not mean M0 avoids parking.

**Next bounded research:** Consider a focused, source-locked one-core **event-only** explanation of why M0 repeats actual waits and P18 avoids them, preserving real wake/generation/close/borrowed TaskRef correctness; if an alternative policy is proposed, test **both** one-core and multi-core uninstrumented native release ABBA plus close/race/join and safety gates. Do not adopt P18 globally, remove condition-variable semantics, busy-spin indefinitely, detect CPU count to set policy without validation, or claim energy/fairness/power gains.

**Disposition: KEEP narrowly scoped P18 research; DEFER universal production.** Production `source/`, `develop`, grandfathered R0.5 PR #35, ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38 and prior benchmark archives stay unchanged.
