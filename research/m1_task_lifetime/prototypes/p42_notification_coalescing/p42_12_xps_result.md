# P42.12 — XPS task-cost evidence (2026-10-17)

Archive: `p42-12-xps-results.tar.gz`; source commit `b569e419862045a36216b9d8eb7f6cbe2fa42d8a`. Compiler LDC 1.42.0, DMD base 2.112.1, LLVM 19.1.7, x86-64 Skylake target. **72 rows / 36 complete pairs**, 4 producers and 4 workers, 131072 tasks/run. CSV SHA-256 `f20c56c5195bc9d844730b2ae9369b886e50278a6e9498089799d61ba6cd56af`. Four binary SHA-256 values match the manifest in the supplied archive.

| Task cost | Baseline median (us) | Conditional median (us) | Median paired delta | Conditional wins |
| --- | ---: | ---: | ---: | ---: |
| Light, 1 atomic hit | 74112 | 70012.5 | -5.74% | 15/18 |
| Medium, 32 extra atomic increments plus hit | 91221.5 | 88127 | -3.16% | 17/18 |

Session-wise medians of paired delta: light -2.51%, -6.72%, -6.65%; medium -2.24%, -5.15%, -4.34%. A negative delta denotes conditional faster. Individual paired changes: light -15.29% to +4.12%, medium -15.34% to +3.93%.

**Interpretation**: The 4/4 benefit survives additional per-task observable atomics but is smaller in median percentage. Medium is **not** a general numerical/compute-heavy workload, and neither variant measures idle-to-active latency. All sessions come from one XPS run; no inter-day independence. This is suggestive performance evidence, not a scheduling-policy release decision.

**CI issue discovered**: the source commit's GitHub run `39057717397` passed LDC 1.41.0 but failed DMD 2.111.0 because the newly added medium Dub configurations included LDC-only `-O3` (DMD: unrecognized switch). Commit `7f63f96ceb8aef03bc75327d29702ea3b6b87c89` removes that flag from only the new medium configurations; follow-up CI must pass before declaring them cross-compiler qualified. No production scheduler change.
