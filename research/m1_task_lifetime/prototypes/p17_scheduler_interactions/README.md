# P17 — Completion, park-state and steal-path interactions

**Date:** 2026-10-13  
**Branch:** `research/m1-task-lifetime-boundaries`, [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Status:** P17 research-only source and CI probe; **complete native Dell-XPS P17 results received and audited**. The earlier P16.2 evidence is [published as a qualified analysis](../p16_2_atomic_completion/evidence/xps-2026-10-13-analysis.md). No production API or scheduler changed.

## Question

P16.2's exact-M0/seq-cst A/B comparison found that eliminating the inbox mutex on open-pool `completeOne` **does not reliably improve throughput for very short tasks** with 2/4 workers: for 0/8/32 iterations the 4-worker atomic/original medians were 1.100/1.111/1.105×. P16.2 also changed measured `parkCount`: at four workers and zero iterations, the medians moved from **169** in M0 to **317** in the candidate. Those are **counts, not sleep durations** and alone do not show why idle transitions differ.

At the same time, the XPS recorded **100°C at the CPU-package high threshold in all six before/after snapshots** and no actual frequency trace. We cannot use those runs to promote the atomic scheduler without a cooler, monitored recheck.

P17 separates **event-path diagnosis** from **uninstrumented speed qualification**. No new wake, parking, stealing, batching or memory-order policy is introduced.

## Source discipline and four arms

The P17 generator `tools/research/m1_p17_make_event_pair.py` requires exact original M0 Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. For its alternative it accepts only the **generated, source-pinned P16.2** variant bearing that same original M0 lineage, and checks the seq-cst completion fetch-add anchor. A source mismatch **fails closed**. All generated files live in ignored research `generated/` paths. The P13 workload generator separately pins the exact P13 kernel and CSV-driver blobs.

| DUB mode | Scheduler source | Extra event counters | Correct use |
|---|---|---|---|
| `control` | Original production M0 | None | **Native performance baseline** |
| `atomic` | Existing P16.2 seq-cst research copy | None | **Native performance comparison** |
| `trace-control` | P17 event-only copy of original M0 | Yes | Diagnostic event distribution only |
| `trace-atomic` | P17 event-only copy of P16.2 | Yes | Diagnostic event distribution only |

All four process variants use the exact same **TaskRef storage and result oracle**, deterministic integer kernel, thread counts, ingress capacities, shuffled sweep order, three-wave timing and native join boundary. The original P16.2 close/generation Condition protocol and seq-cst handshake remain **unchanged**. No `@safe TaskScope` safety claim is added, and native start/join exceptions remain an unresolved @system failure boundary.

## The new event distinction

P17 counts for both scheduler sources:

- Actual per-worker local pop **hits** and **misses**;
- inbox `takeBatch` **attempts**, nonempty claims and claimed TaskRefs;
- actual cross-worker **steal attempts** and successful steals, so failed attempts can be derived;
- per-worker attempts to enter the park protocol;
- existing actual `Condition.wait` entries (`parkCount`);
- for each such wait, whether **accepted − completed was zero or positive while holding the original Condition mutex**;
- per-worker TaskRef executions and the minimum/maximum executed-task count across configured workers.

When the inbox is empty, **zero outstanding tasks** means the pool had no admitted incomplete work when a worker actually slept. A **positive outstanding count** may mean another worker is executing work or work resides in a local deque – P17 **cannot distinguish these situations** from the aggregate counter. Therefore `park_with_outstanding` is **not a lost-work or incorrect-wake count**. Workers are allowed to sleep if all remaining work is being executed elsewhere. `park_no_outstanding` is not an error either: before closure workers may legitimately wait for new submissions.

Every worker writes its own cache-line-aligned event struct, read **after** successful native joins. The two park-state bins increment **under the original TaskInbox/Condition mutex**; there is no extra lock, sampling clock read, per-TaskRef allocation or inter-worker atomic merely to collect statistics. Nevertheless **extra counters change cache traffic, critical-section duration and scheduling**, and traced mode timings must **NOT** be compared as performance. Original and atomic *uninstrumented* arms alone provide timed A/B evidence.

The independent P17 validator requires identical workload/order/seed/checksum for all four arms; zero diagnostic columns in uninstrumented modes; exact task accounting; `park_waits == park_no_outstanding + park_with_outstanding`; `park_waits <= park_attempts`; successful steals <= attempts; and feasible per-worker execution minima/maxima. Any mismatch fails the qualification regardless of timings.

## CI and native experimental method

The [DMD/LDC P17 preflight](../../../../tools/research/m1_p17_probe.sh) runs a 6-case smoke and all **45 native-profile combinations** with small task counts, preserving previous research compiler baseline DMD 2.111.0/LDC 1.41.0. Both compilers must produce the same TaskRef results in all four modes; LDC additionally exercises whole-release-mode correctness. Timing ratios from shared CI are **diagnostic only**. The full earlier P01–P16.2 gates remain in the workflow.

The foreground [P17 XPS collector](../../../../tools/research/m1_p17_xps.sh) repeats the 45-case P13-native profile with identical order/seed in **all four arms**, rotates process order across four default sessions, with **2 warm-up + 5 measured sweeps**, 2,048 jobs per wave × three waves and 1/2/4 physical-worker scenarios. The allowed logical CPUs are chosen from four **distinct physical cores** by default; `P17_CPUSET` overrides the process affinity. Workers themselves are **not individually pinned**.

**Thermal preflight is deliberately conservative** after the P16.2 100°C observations. By default, [read-only sysfs telemetry](../../../../tools/research/m1_p17_telemetry.py) refuses to start a performance study if the package sensor is missing or already **≥95°C**. An explicit `P17_ALLOW_HOT=1` allows **exploratory diagnosis only**. While each of the four processes runs, a uniformly applied 500-ms sampler saves package-temperature, sysfs-reported `scaling_cur_freq` and readable package-throttle counters per allowed CPU to a separate CSV. The [thermal review](../../../../tools/research/m1_p17_thermal_review.py) flags temperatures ≥95°C, unavailable sensors or throttle counter increases as **NOT QUALIFIED**. Even a screening pass is **not proof of constant CPU clocks** or lack of rapid throttling between samples. Running this monitor also creates small measurement overhead applied to all variants.

Recommended XPS command:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin research/m1-task-lifetime-boundaries
git worktree add --detach ../concurrency-d-p17 \
    origin/research/m1-task-lifetime-boundaries
cd ../concurrency-d-p17
bash tools/research/m1_p17_xps.sh ldc2 /tmp/p17-xps-2026-10-13
```

If `../concurrency-d-p17` already exists, use a new worktree path rather than overwriting any ongoing work. The runner refuses to overwrite destination data. The resulting archive is `/tmp/p17-xps-2026-10-13.tar.gz` with original benchmark CSV/raw logs, event-comparison diagnostics and per-process thermal/frequency traces. **Review raw user/host/path identifiers before public sharing**.

## Decision boundaries

P17 will test whether the additional P16.2 park events occur predominantly when no obligations remain (idle between producer bursts) or when outstanding work still exists, and whether the pattern accompanies extra failed steals or changed batch-claim behavior.

Neither result, alone, proves that the atomic completion path **causes** more parking; the variants may simply change scheduling interleavings. Any proposed fix must alter **one mechanism at a time** and preserve exact admission/completion, Condition generation/no-lost-wake, TaskRef lifetime and real native joins.

**No production promotion** of P16.2, no weaker memory orders, no new public `@safe` contract, no optimized-release superiority claim from a hot machine, and no C++/Rust parity assertion. ADR-0001 stays PROPOSED, Issue #17 OPEN, Draft PR #38 DRAFT, original `source/`, `develop` and grandfathered R0.5 PR #35 untouched.


## Native Dell-XPS result (2026-10-13)

The [complete P17 original-archive review](evidence/xps-2026-10-13-analysis.md) records SHA-256 `ee96d2f1d9b5d903de3ec667d5d0e3e4e8637b61932cf2c652aceef6afaff6aa`, source commit `331c35cb`, LDC 1.41.0 release and four process-affined physical cores. All 16 raw logs agree with their corresponding CSVs; **5,040 rows** comprise **1,440 warm-ups plus 900 measured rows per arm**. Same-work TaskRef, checksum, stage-time and trace event-conservation gates PASS. Raw files containing user/host/path details have not been published.

In **900 matched UNINSTRUMENTED atomic/original comparisons**, the median was **0.9308× overall**, but **0.8205× / 1.0216× / 1.0430×** at 1/2/4 workers respectively. For four workers with 0/8/32/128/512 kernel iterations, median ratios were **1.131 / 1.143 / 1.133 / 0.967 / 0.668×**. The candidate remains slower on very short four-worker tasks.

In **60 four-worker/zero-iteration TRACE runs per arm**, median `Condition.wait` entries were **148.5 original / 305 atomic**. No-outstanding parks: **85 / 215**; outstanding parks: **69.5 / 93.5**. Median within-run unsuccessful steals: **950 / 1,864.5**; successful steals: **275 / 280**. Instrumented paths change scheduling and do not measure event cost; uninstrumented park counts belong to different runs and must not be combined algebraically with the trace bins. Additional idle transitions and steal searches are explanatory **hypotheses**, not causal proof.

**Thermal gate:** `P17_ALLOW_HOT=0`. Recorded 500-ms temperatures span **53–93°C**; **15 of 16 traces** passed the limited screen, and **session-1 trace-atomic** showed one thermal-throttle-counter increment. All eight uninstrumented arms passed their limited screen, but the supplied full-run thermal verdict is **PERFORMANCE NOT QUALIFIED**. Per-thread effective clock stability is unproven; no general production speed claim follows.

**Decision:** KEEP P17 evidence and P16.2 as research. Do not change production M0, weaken seq-cst wake ordering, promote general `@safe`, or claim C++ parity. Any next one-variable park/search experiment requires adversarial no-lost-wake, close/join and same-work controls. ADR remains proposed, Issue #17 open, PR #38 draft, `develop` and grandfathered R0.5 unchanged.
