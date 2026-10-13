# P17 — Dell XPS four-arm scheduler event, speed, and thermal evidence (2026-10-13)

**Verdict:** Complete source archive/integrity checks **PASS**. The uninstrumented P16.2 seq-cst completion candidate **still loses throughput for tiny tasks with 2–4 workers**; its instrumented research counterpart enters `Condition.wait` and performs failed steals much more often, predominantly on transitions with **no outstanding accepted-but-incomplete work**. This is a **scheduler-interleaving correlation**, **not a demonstrated causal time budget**. Thermal screening is much improved over P16.2 but **not fully qualified: one of sixteen process traces shows a package throttle counter increment**. **KEEP research only; NO-GO production or public `@safe` promotion.**

## Original provenance, source and confidentiality

- User-supplied `p17-xps-2026-10-13.tar.gz` size **436,088 bytes**, SHA-256 **`ee96d2f1d9b5d903de3ec667d5d0e3e4e8637b61932cf2c652aceef6afaff6aa`**. The original full archive includes local host/user/path data in DUB logs and the manifest. **Do not upload the raw archive to public GitHub.** This report contains only sanitized evidence aggregates; original files remain in the research exchange.
- Source provenance from the saved manifest: git commit **`331c35cb684ad9cc00bd84f256e1b6fb4ac8e360`**, exact original M0 Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, **LDC 1.41.0** (DMD frontend 2.111.0), **whole DUB release**. All four arms share the exact P13 TaskRef kernel, work oracle and checked successful native-worker join protocol.
- Hardware: Dell XPS 15, Intel Core i7-9750H, process affinity `0,1,2,3` mapped to four distinct physical cores. **Not pinned per worker.** Four sessions use rotated **whole-process** ordering of `control`, `atomic`, `trace-control` and `trace-atomic`, with identical within-session shuffled scenario ordering. Four processes are executed sequentially; comparisons are matched by scenario/seed/sweep but are **not concurrent paired experiments**.

## Audit of ALL original archive contents

- Archive contains **60 regular files**, comprising 16 normalized per-mode/session CSVs, 16 matching original DUB raw logs, 16 per-process thermal/frequency telemetry CSVs, 8 comparison/order diagnostics, and original manifest, thermal reviewer/summary and event summary.
- **Every one of the 16 normalized benchmark CSVs agrees byte-for-byte with the CSV records extracted from its corresponding original raw DUB log.**
- Four sessions × four arms × 45 settings × (two warm-ups + five measured sweeps) = **5,040 records**: **1,440 warm-ups** and **3,600 measured records** (**900 per arm**). Every one of the **112 mode/session/sweep blocks** contains exactly one case per 1/2/4 workers × 0/8/32/128/512 unsigned workload iterations × ingress 8/64/256, with 45 unique `order` indices. Each case represents **three waves × 2,048 = 6,144 completed real TaskRefs**.
- Every corresponding four-arm row (including warm-ups) has exactly equal `phase/round/order/seed/workers/count/waves/iterations/ingress/checksum`. All stages are nonnegative and satisfy `prepare_ns + pool_start_ns + waves_ns + join_ns + verify_ns == total_ns`. The two **uninstrumented** arms emit **zero** P17 event counters.
- Every original/atomic event-traced row has `batch_tasks=6144`, `park_waits = original park_count = park_no_outstanding + park_with_outstanding`, `park_attempts >= park_waits`, `steal_successes <= steal_attempts`, and feasible worker-task minima/maxima. The fixture's separate **per-worker execution sum and exact result oracle** remain checked inside its optimized D process after native join.
- The successful program completes with all work checks satisfied. **This archive does not introduce injected native start/join faults, arbitrary `@safe` borrowing, or new shutdown proof.** The existing P16.2 exceptional native-worker lifecycle **NO-GO** remains.

## Uninstrumented control-versus-candidate: overall is misleading

Only `control` and `atomic` (both **without P17 instrumentation**) are used for speed. A ratio `R=atomic.waves_ns / original.waves_ns` is computed within each matched session/sweep/configuration; **R < 1** favors seq-cst atomic. `waves_ns` covers repeated real submit/execute/wave completion but excludes preparation, pool start, final join and oracle verification. Never infer an overall production speedup from the workload-mix aggregate.

| All 900 measured matched configurations | Value |
|---|---:|
| Median atomic/original ratio | **0.9308×** |
| Candidate faster | **558/900** |
| Median ratio with **1 worker** (300 samples) | **0.8205×**, wins **297/300** |
| With **2 workers** (300 samples) | **1.0216×**, wins **140/300** |
| With **4 workers** (300 samples) | **1.0430×**, wins **121/300** |
| Median ratios per session | **0.9465 / 0.9091 / 0.9145 / 0.9469×** |

Medians by worker × work size; each cell **60** same-setting worker/iterations comparisons (4 sessions × 5 measured sweeps × 3 ingresses):

| Workers | 0 iterations | 8 | 32 | 128 | 512 |
|---:|---:|---:|---:|---:|---:|
| 1 | **0.823** | **0.807** | **0.828** | **0.581** | 0.944 |
| 2 | **1.147** | **1.134** | **1.055** | **0.642** | **0.828** |
| 4 | **1.131** | **1.143** | **1.133** | 0.967 | **0.668** |

**At 4 workers, 0/8/32-iteration tasks regress by ~13–14%** at median, despite removing the original per-task completion mutex; these regressions are consistent in direction with the earlier [P16.2 XPS experiment](../../p16_2_atomic_completion/evidence/xps-2026-10-13-analysis.md). At 512 iterations the atomic variant is substantially faster in all 60 matched four-worker runs. The unusual one-worker/128-iteration effect (**0.581×**) persists: no steal path or concurrent worker-completion pressure is necessary for this result, and its actual cause is not established.

**Worker scaling remains workload-specific:** within the unchanged M0, 4-worker/2-worker median ratios across 60 same-session/sweep/ingress comparisons for 0/8/32/128/512 iterations were **1.603 / 1.573 / 1.394 / 1.076 / 0.896**. Within the seq-cst candidate they were **1.541 / 1.616 / 1.482 / 1.561 / 0.708**. Neither variant makes the shortest workloads scale well from two to four workers; the candidate is markedly worse in **relative** 4w/2w scaling at 128 iterations because its two-worker absolute case improves more.

## What P17 EVENT-ONLY counters establish

**Do not combine independent arm medians as if they were one execution.** Source event bins are collected in the separate `trace-control` and `trace-atomic` processes; they cannot be algebraically summed with `park_count` from the uninstrumented processes, even though each trace internally satisfies `park_waits=park_no_outstanding+park_with_outstanding`. They count **events, not waiting time or time spent stealing**. Instrumenting a lock-protected park-state bin and worker-local stats changes schedule timing. Trace versus uninstrumented measured wave-time ratios are therefore not an accepted overhead correction.

For **four workers, zero compute iterations**, medians from **60 trace observations per mode** spanning all three ingress sizes:

| Event in event-only traced copies | Original trace | P16.2 trace |
|---|---:|---:|
| Actual `Condition.wait` entries (`park_waits`) | **148.5** | **305.0** |
| `park_no_outstanding` | **85.0** | **215.0** |
| `park_with_outstanding` | **69.5** | **93.5** |
| All victim-deque steals attempted | **1,221** | **2,149.5** |
| Successfully stolen Tasks | **275** | **280** |
| Failed steals, median of **run-level** differences | **950** | **1,864.5** |
| Median within-run share of parks with no outstanding Tasks | **57.8%** | **72.2%** |

The **separate uninstrumented** copies for the same 4-worker/zero-iteration scenarios had `park_count` medians **156.5 original** versus **321 candidate**, consistent in **direction** with the trace data but **not the same rows/events**.

The **dominant increase in sleeping events occurs with zero accepted-but-incomplete tasks** at the instant of entering `Condition.wait`, and failed steals grow strongly while successful steals barely move. **Interpretation:** these are repeated attempts to find work and sleep at boundaries of producer/worker bursts, consistent with changed task admission/drain timing. It does **not** demonstrate a missed wake, starvation, task-loss, too-long sleep, or the per-event time cost. Parking with outstanding work is allowed when another worker is already running it.

### Ingress=64: controlled example with 4 workers and zero iterations

There are **20 matched measured sweep/configuration tuples** (four sessions × five measured sweeps):

| Measure | Original | Atomic |
|---|---:|---:|
| **Uninstrumented** median atomic/original `waves_ns` ratio | \- | **1.165×**, atomic slower **20/20** |
| **Trace** `park_waits` | **137.5** | **294.5** |
| **Trace** no-outstanding parks | **80.0** | **202.0** |
| **Trace** with-outstanding parks | **62.0** | **87.5** |
| **Trace** failed steals, median of per-run attempts−successes | **867.5** | **1,775.5** |
| **Trace** nonempty inbox batch claims | **961** | **1,095** |

These differences are robust in sign across the 20 sequential but scenario-matched runs, **not 20 independent machine experiments**. For zero-iteration tasks with ingress 256, atomic/original median was **1.183×**, with more no-outstanding parks and failed steals in atomic. With ingress 8, both versions have substantially more backpressure/search activity, so the ratio is closer to **1.065×** without implying either is fast.

For 4 workers/128 iterations/ingress 64, the atomic variant was **slightly faster at median (0.952×)** yet showed far more event activity (failed steals ~194.5→~1,242.5, no-outstanding parks ~15→~118.5). Thus event counts and time effects do not have a fixed relationship. At **512 iterations/ingress 64**, atomic/original was **0.672×**, and the atomic trace showed **fewer** unsuccessful steals and park events. A single scheduling-path culprit is **not demonstrated** by this matrix.

## Thermal and clock screening: materially better but NOT a clean speed qualification

The P17 runner recorded **`P17_ALLOW_HOT=0`**, using its default initial package-temperature gate **below 95°C**; it was not bypassed. Unlike the earlier P16.2 XPS run (100°C at every session-boundary snapshot), the new `thermal-summary.csv` reports **16 monitored mode/session process traces**, generally **53–93°C** across the saved 500-ms package readings.

- **15 of 16 traces:** `SCREEN_ONLY_NOT_PROOF` (saved package temperatures below 95°C and no increase in readable throttling counters).
- **One trace, session 1 `trace-atomic`:** `NOT_QUALIFIED` because a **package thermal-throttle counter increment of 1** was observed, despite observed package temperatures never reaching 95°C at the sampled points (max **92°C** in that process).
- **Both uninstrumented mode traces in all four sessions (8 traces)** passed the limited thermal screen; neither sampled package temperature nor readable package-throttle counter increment alone shows sustained throttling in those speed arms.
- The frequency series records Linux `scaling_cur_freq` readings, ranging from around **800 MHz to 4.5 GHz** across sampled logical CPUs; these are **sysfs-reported values, not constant-clock/per-thread execution-frequency measurements**, and may capture idle moments rather than active worker cycles.
- Individual processes have only **3–7 samples** at **500-ms** intervals. Brief clock drops/thermal transients between samples, per-thread migrations and power/turbo effects remain unobserved. Four sequential sessions on one laptop are not four independent machines.

The original built-in reviewer correctly concludes **P17 PERFORMANCE NOT QUALIFIED** for the *entire 16-process archive* because of the observed throttling count in the trace-atomic arm. Do **not** overstate this as confirmed throttling in uninstrumented original/atomic speed arms. It is nevertheless a **real qualification red flag**: claim qualitative, reproducible **within this cooled setup**, not thermally proven production performance or general cross-platform speed superiority. Repeat target runs with denser clock/power/thermal monitoring and stronger thermal headroom before promotion.

## Outcome and narrow next hypotheses

**KEEP:** P17 source-protected event instrumentation, complete four-mode archive integrity, 900 paired **uninstrumented** speed comparisons, path counts and two-bin park classification, and the 16 read-only thermal records. Store original source hash and findings, not user-bearing raw log archives, in GitHub.

**Supported narrower interpretation:** P16.2 completion accounting, while correct under its tested close/final-wake/producer protocols, changes work-handoff interleavings: short 2/4-worker tasks correlate with **more no-outstanding idle parks, failed steal searches and smaller/more numerous ingress batch claims**, and the candidate is usually **slower** there. The original M0 short-workload 4w/2w scaling issue also remains. Neither a lock-free completion rewrite nor indiscriminate worker throttling is justified yet.

**DEFER:** a new wake/park/backoff algorithm, completion batching, work-steal policy, non-seq-cst orders, dynamic thread counts, general `@safe TaskScope`, native start/join exception safety, C++/Rust parity, or an unconditional production scheduler default from these measurements.

**Proposed P18 research question (NOT implemented):** isolate **one** scheduling transition (e.g. the post-empty-search park handoff or a narrowly bounded worker-local retry/grace period) as an exact-source experimental variant. Any variant must retain the original generation/Condition no-lost-wakeup invariant, close/last-completion wake, full native joins, original TaskRef ownership and fair same-work A/B runs. First document state-machine cases and adversarial close/park/submit races; a faster result at 100°C or with changed lifetime obligations must be rejected. Distinguish actual no-work park/wake time from counter frequency with appropriately calibrated low-perturbation tools, if available.

**Governance:** ADR-0001 **PROPOSED**, Issue #17 **OPEN**, Draft PR #38 **DRAFT**; no edits to production `source/`, `develop`, or grandfathered R0.5 PR #35. The earlier P16.2 seq-cst completion remains an **unpromoted** research-only option.
