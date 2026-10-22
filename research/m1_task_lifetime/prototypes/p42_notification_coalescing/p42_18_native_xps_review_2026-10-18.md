# P42.18 — native XPS end-to-end review (2026-10-18)

**Disposition: positive research performance candidate — KEEP; production switch/merge — NOT QUALIFIED.** The primary *pre-registered* Light threshold is met. This justifies an independent, thermally controlled native replication, not a policy change. PR #38 remains Draft and ADR-0001 remains Proposed.

## Input, provenance and independent audit

- Complete user-uploaded `p42-18-xps-01.tar.gz`, SHA-256 `0f38866242a3447eebbb7865bcb3684633e577b3e3b8f06d9b3fcd8b3cf0bfc4`.
- Native source-commit `243e3898d610c9a601a91e8d0fbdda001bf7a3c9`, empty tracked worktree status (captured with `git status --porcelain=v1 -uno`, which omits untracked files). Its exact-head [CI #39114348561](https://github.com/alex-1974/concurrency-d/actions/runs/39114348561) passed DMD 2.111.0 and LDC 1.41.0.
- Native compiler **LDC 1.42.0 / frontend 2.112.1 / LLVM 19.1.7**, DUB 1.40.0, `dub build --build=release --force`. The native compiler differs from the CI LDC version. Host: Intel Core i7-9750H (six physical/twelve logical cores), Linux x86-64, `powersave` governor, CPU affinity 0-11. Run window 2026-10-18 10:04:27–10:05:03 UTC.
- Both original binaries and build logs for the four cost × policy variants are present. SHA-256 manifests verified **4/4 binaries**, **291/291 result files** (288 raw logs + three CSVs). `sources.sha256` is present, but source contents are not included in the archive, so source hashes cannot independently be rechecked *solely from the uploaded bytes*.
- Independent raw parsing validated **288 exactly-once benchmark stdout lines**, **144 completed policy pairs**, **six sessions × six cycles**, exactly **131,072 tasks/run**, correct dimensions, **exact balanced execution order**, and perfect reproduction of both `paired.csv` and `sessions.csv`. The unmodified consumer emits its output only after accepted/completed and once-only task checks.

## Experiment boundaries

The same preexisting `p42_benchmark.d` is run on both arms, using uninstrumented source-derived production baseline versus legacy conditional overlay. No P42.16/17 per-worker diagnostics, task timestamps or flow counters. The conditional variant necessarily adds its own minimal waiter counter. Light tasks perform a hit counter increment; Medium performs 32 additional atomic increments/task. The elapsed microsecond measurement includes pool construction, producer submission, worker execution and close/join, with record validation after timing. Both arms do **identical work within each task cost**.

The 4-producer/4-worker workload is the primary target. The 1-producer/1-worker workload is an *also policy-exposed* control to detect broad drift, not a CPU-normalization oracle.

Each reported delta is **100 × (conditional elapsed / baseline elapsed − 1)**; negative favors conditional. The primary median is taken over 36 within-pair percentage differences, **not** computed from pooled medians.

| Workload | Baseline pooled median (µs) | Conditional pooled median (µs) | Median paired delta | Conditional faster |
|---|---:|---:|---:|---:|
| **4P/4W Light** | 73,483.5 | 63,550 | **−10.41%** | **32/36** |
| **4P/4W Medium** | 86,989 | 82,271 | **−5.92%** | **29/36** |
| 1P/1W Light control | 30,864 | 30,657 | +0.07% | 17/36 |
| 1P/1W Medium control | 62,720 | 63,441.5 | +1.32% | 11/36 |

### Session-level paired percentage median

| Session | 4P/4W Light | 4P/4W Medium | 1P/1W Light | 1P/1W Medium |
|---:|---:|---:|---:|---:|
| 1 | −9.96% | −4.64% | +0.63% | +3.65% |
| 2 | −17.76% | −8.15% | +0.63% | −0.02% |
| 3 | −14.94% | −14.58% | −0.57% | +1.47% |
| 4 | −14.70% | −9.10% | −3.98% | +1.74% |
| 5 | −11.54% | −2.54% | −0.39% | +1.48% |
| 6 | −4.16% | −4.67% | −0.45% | +3.80% |

**Pre-registered Light screening gate PASSED:** at least five of six session medians were required to improve by at least 3% and none regress by more than +2%; **all six** improved by at least 4.16%. All six Medium session medians also favored conditional. Over matched cycle IDs, the median target-minus-control paired delta is −10.87 percentage points (Light, 28/36 negative) and −8.79 pp (Medium, 31/36 negative); these are **diagnostics, not normalized speedups**.

## Major threats to production qualification

1. **Pronounced run-order effect despite balancing.** For 4P/4W Light, the median paired change is −18.17% when baseline runs first (17/18 conditional wins), versus −5.95% when conditional runs first (15/18 wins). For Medium the corresponding values are −7.59% (15/18) and −4.50% (14/18). Different magnitudes suggest temporal/system effects that require controlled replication.
2. **Strong thermal ramp.** In **44 snapshots**, recorded CPU-package temperatures span **58–100°C**; **nine** snapshots are >=95°C and two reach **100°C** (Session 6). This reaches the sensor's reported high/critical temperature; sparse snapshot observations cannot confirm or quantify throttling. Frequencies across logical CPUs ranged about **0.8–4.3 GHz**; no pinning or governor control was imposed. Session 6 samples were **95–100°C**.
3. **Replays are temporally clustered.** All six nominal sessions completed during one **36-second** continuous capture; they are not six independent thermally reset experiments. Task observations or 144 paired process invocations must not be treated as iid inferential units. No definitive confidence interval or platform-general speedup is claimed.
4. **Mechanism evidence is from a different experiment.** P42.17 showed suppressed `notify()` calls in a separate heavily instrumented test. P42.18 cannot attribute its performance effect to a particular number of saved kernel wakes, local work claims, or scheduler fairness improvement.
5. **Scope remains narrow:** one native machine/compiler, one count of 131,072 tasks, two costs, 1P/1W and 4P/4W only. No cross-platform or public API/lifetime guarantee follows.

## Decision and next evidence gate

**KEEP** the positive native P42.18 result intact as compelling **candidate evidence**. **GO only for independent source-pinned native replication** with the **same semantics** and more stable CPU/thermal operation. Separate sessions/cooldown, record frequency and temperature during and between pairs, retain balanced AB/BA and the 1P/1W diagnostic control, and predeclare pass/fail boundaries before observing the new run. A favorable independent replicate may justify a separate production-design/ownership safety review; it is **not** automatically permission to merge or promote the policy. If the advantage shrinks or reverses, retain that contrary evidence as well.

**No code changes, no merge, no production scheduler switch, no release, no ADR acceptance; PR #38 stays Draft.** Independent analysis products (audit source, all 144 paired rows, 12 session rows, summary JSON, and full Markdown review) are available as a separate checksummed conversation artifact; the raw XPS archive remains immutable.
