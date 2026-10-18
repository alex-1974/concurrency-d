# P42.19 — cooled native XPS replication review (2026-10-18)

**Decision: P42.19 replication PASS at the pre-registered research screening boundary.** Conditional notify remains a **qualified performance candidate**, *not* a production-approved or lifetime-safe scheduler policy. Follow-up: separate task-lifetime/ownership, progress, consumer-use and design review. PR #38 remains Draft, ADR-0001 stays Proposed; no merge, source switch or API change.

## Source-pinned input and evidence validation

Uploaded full archive: `p42-19-xps-01.tar.gz`, SHA-256 `9065d7515b4ff05060d98f31e1163ba28781c20f85efe72b1c75d8ce581f317e`.

- `commit.txt`: `329469c38472466667bc2ce7e032675d8beebe13`, exactly the [DMD 2.111.0/LDC 1.41.0 CI-qualified HEAD (#39120059305)](https://github.com/alex-1974/concurrency-d/actions/runs/39120059305). The native test used **LDC 1.42.0** (DMD frontend 2.112.1, LLVM 19.1.7) and DUB 1.40.0; this is distinct from the pinned CI LDC.
- Complete 2026-10-18 **10:50:03–11:09:02 UTC** capture; build logs for all four release binaries, CPU/platform telemetry, source-hash manifest, binary-hash manifest, `run_state.txt` = `COMPLETE` and an empty tracked-worktree status captured with `git status --porcelain=v1 -uno`. Untracked files are outside that status check.
- SHA-256 independently confirmed on **all 4/4 included binaries** and **292/292 included result files**: 288 distinct raw stdout logs, `results.csv`, `paired.csv`, `sessions.csv`, `thermal.csv`. The manifest stores native absolute paths; these were mapped to the same relative paths inside the archive *without changing the expected digests*. `sources.sha256` exists, but the source bytes themselves are not inside this archive; the source hashes cannot be recomputed from the archive alone.
- Independently parsed the **288** original stdout records and verified **144/144** complete arm pairs, **exact recorded AB/BA order**, fixed **131,072 tasks** and P/W dimensions, arm ID, positive `elapsed_us`, raw/`results.csv` agreement, and exact recalculation of every row in `paired.csv` and `sessions.csv`. The original benchmark emits its result only after its accepted/completed and once-only task correctness checks.
- Independently audited `thermal.csv`: **1,176 events** comprising **600 probes**, 288 cool `ready` and 288 `post` events; every pair of final consecutive pre-run probes was at most **70,000 m°C**, separated by at least 3 seconds; all 288 post-run samples were **below 95,000 m°C**, in fact **43–70°C**. Session boundaries had gaps of **33.48–36.46 seconds**; longest pre-run cooldown was ~27 seconds. The maximum of *all preliminary, not necessarily ready* probe readings reached **93°C**. Additional coarse sensor snapshots show 44–87°C. The snapshots **cannot prove absence of in-run frequency or temperature excursions**. Powersave governor and CPU affinity 0–11 were recorded; frequency snapshots spanned roughly **0.8–4.4 GHz**, without attempted governor/pinning changes.

## End-to-end comparison: independent paired percentage differences

Same established `p42_benchmark.d` consumer, original production baseline and legacy minimal conditional overlay; no P42.16/P42.17 diagnostic worker TLS, flow counter, or per-task timestamps. Each run times pool construction, producer submissions, execution and close/join. The conditional arm's waiter counter is inherent policy overhead. All results below are descriptive relative time differences: `100 × (conditional_us / baseline_us − 1)`; **negative favors conditional**.

| Workload | P42.18 median paired | **P42.19 median paired** | P42.19 conditional faster pairs | P42.19 baseline/conditional pooled median µs |
|---|---:|---:|---:|---:|
| **4P/4W Light** | −10.41% | **−7.69%** | **29/36** | 70,364.5 / 64,397 |
| **4P/4W Medium** | −5.92% | **−4.82%** | **27/36** | 85,070.5 / 82,032.5 |
| 1P/1W Light control | +0.07% | −1.21% | 25/36 | 31,106.5 / 30,500.5 |
| 1P/1W Medium control | +1.32% | +0.38% | 15/36 | 61,869 / 62,020 |

Pooled task/process medians and paired medians use different aggregation operators and must not be casually substituted. The 1P/1W control **also executes the tested policy** and is not a policy-independent temperature normalization oracle.

### Pre-registered session medians (% conditional minus baseline)

| Session | Target Light | Target Medium | Control Light | Control Medium |
|---:|---:|---:|---:|---:|
| 1 | −5.54 | −0.96 | +2.10 | +0.34 |
| 2 | +0.02 | −5.10 | −2.74 | +1.17 |
| 3 | −5.84 | −8.20 | −3.53 | −0.64 |
| 4 | −8.75 | −2.40 | −0.75 | +2.72 |
| 5 | −13.70 | −4.93 | −2.75 | −0.66 |
| 6 | −5.90 | −4.63 | −0.65 | +1.60 |

**Pre-registered P42.19 gate assessment:**

- **Light: PASS**. At least 3% improvement in **5/6** target session medians and no target session regression above +2%. Session 2, at +0.02%, was effectively neutral; it was not removed.
- **Medium: PASS** at the negative-regression screening threshold: **6/6** target session medians favor conditional; none regress above +2%.
- **Order sensitivity: PASS** at the declared 5-percentage-point trigger. Target Light: median −5.90% when baseline first, −9.35% when conditional first (difference **3.45 pp**); Medium: −5.11% versus −4.49% (**0.63 pp**). This screen does not establish perfect run-order neutrality.
- **Thermal trace: PASS**, all 288 processes admitted and closed within the declared snapshot limits. In-process thermal spikes remain unknown.
- **Control: interpretable, not causal**. Light 1P/1W control itself improved a little (−1.21% median paired); it does not explain away the larger 4P/4W improvement by itself, but cannot rule out shared scheduling or CPU-state effects.

P42.18 had reached 100°C and Light target AB/BA order medians −18.17% versus −5.95%; the independent P42.19 cooled capture reproduced a somewhat smaller favorable effect with markedly less order sensitivity. These are two **separate same-machine/time-window captures**, not independent platforms, clocks, or six statistically independent laboratories.

## Interpretation and next boundary

**KEEP positive P42.18 and P42.19 native optimized end-to-end results.** The pre-registered replication threshold was met and the experiment is no longer *merely an unconfirmed timing candidate*. This warrants a **separate production-design/lifetime and consumer-benefit investigation**, not an automatic implementation decision.

**NOT established:** which specific wakeups/notifications caused the speedup; reduced *kernel* wakes or energy; starvation freedom; adversarial progress and close races beyond existing finite gates; all worker-count/task-shape generalization; 24h thermal stability; public API/task ownership safety; universal cross-machine/compiler benefit.

**No production source or public API changes.** PR #38 remains Draft, ADR-0001 Proposed; no rebase, merge, branch retarget, release or workspace/sibling repo modification. Preserve all previous P42 evidence and this full uploaded archive (SHA above) immutably outside production Git history. Derived independent audit artifacts (script, summary, paired and session CSVs) are separate from native evidence.
