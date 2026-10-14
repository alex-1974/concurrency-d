# P18 — One bounded idle-search retry before parking (research only)

**Research date:** 2026-10-13  
**Scope:** one scheduling transition, not a new executor family.  
**Branch:** `research/m1-task-lifetime-boundaries`, [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Status:** exact-source candidate and original-M0 control **CORRECTNESS-QUALIFIED** on DMD 2.111.0 / LDC 1.41.0 ([CI #38469074496](https://github.com/alex-1974/concurrency-d/actions/runs/38469074496), including LDC `-O3` and full release); **native P18 XPS partial and complete observational evidence now retained** (see below). Do not promote this candidate to production.

## Evidence motivating P18

The [P17 four-arm native Dell-XPS analysis](../p17_scheduler_interactions/evidence/xps-2026-10-13-analysis.md) established a reproducible P16.2 **atomic-completion regression** for very short 2/4-worker tasks. At four workers, 0/8/32 iteration atomic/original `waves_ns` medians were **1.131 / 1.143 / 1.133×**. The event-only P17 counterparts (four workers, zero iterations) recorded median failed foreign-steal attempts **950 original vs 1,864.5 atomic** and `Condition.wait` entries **148.5 vs 305**, of which no-outstanding-task waits were **85 vs 215**. Thus more *attempted* work searches and sleeps occur, particularly during periods with no admitted incomplete work. This does **not** prove the causal time cost of the search-to-park transition or imply a missed wake.

P17's 16 process thermal records showed sample temperatures below 95°C; one trace-atomic process had an increased throttle counter, so **full performance thermal qualification was not achieved**. This supports another carefully monitored A/B research test, not unconditional promotion of either P16.2 or P18.

## Hypothesis, bounded candidate and falsification

**Testable hypothesis:** a single additional worker-local search pass before calling `Condition.wait` can sometimes pick up short-burst work that would otherwise force an expensive sleep→wake transition. It might reduce `parkCount` and increase throughput, especially on frequent producer-burst boundaries.

**Competing hypothesis:** another yield/search cycle doubles unsuccessful steal scans per idle episode, consumes CPU, increases cache traffic and may worsen latency/throughput; if producer is idle, sleeping immediately is preferable. Any observed reduction in `parkCount` without improved **un-instrumented** wave latency is **not** a performance win.

The [P18 source-locked generator](../../../../tools/research/m1_p18_make_grace_pool.py) requires original production-M0 `submission_pool.d` **Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**. It produces a separately named `concurrency.research.m1_p18_grace_pool` in a Git-ignored `generated/` directory, or aborts on changed source/anchors. It changes **only one worker-local grace policy**:

- After the ordinary owner-local pop, inbox batch claim and full foreign-deque victim scan all fail, first call the **existing** `isDrained()`. If drained, exit immediately as before.
- Otherwise, at most **one** `Thread.yield()` and **one** extra full scheduler search pass. No blocking, sleeping or indefinite spin occurs during this grace; the OS is free to schedule another thread during the yield.
- Successful local work, inbox work or successful stealing resets the retry allowance. If the second full scan is also empty, call the **unchanged** `parkUnlessChanged(observed)`. The second scan captures a **fresh** generation ticket before checking ingress and victims.
- No new shared mutable data, atomic counters, new memory orders, work queue, condition variable, task representation, callback timing or native join policy. The only added state is a **worker-local retry counter**, fixed at one. The source-level policy does **not** adapt to task size, worker count or OS environment.

The preserved M0 implementation continues to own the queue/accepted/completed/closed/generation state with its original shared Mutex and Condition. **P18 does not include the P16.2 atomic-completion alternative.** We isolate the idle-search/park handoff against original M0. P16.2 remains a distinct, non-promoted result.

## Why the original wake protocol should remain correct

The original worker captures `observed = wakeGeneration()` *before* its inbox/foreign-deque search. The ticket is checked while holding the Condition mutex inside `parkUnlessChanged`: a published inbox TaskRef, deque announcement, `close` and final shutdown completion increment the generation and notify under that same mutex. Calling `Condition.wait` atomically releases the mutex while sleeping.

The candidate's extra iteration restarts at the top of the **existing** loop, captures a fresh ticket and re-searches every source of runnable work. If publication races after its new ticket, the original generation check stops it from sleeping on a stale search. If publication occurred before its new ticket, it searches the corresponding inbox/queues under the preexisting synchronization protocol. A foreign worker executing the TaskRef, with no runnable record left, does not require all other workers to stay awake. The existing `isDrained()` and `closeAndJoin()` remain untouched.

This is a **local ordering argument under the original condition-generation contract**, not a general formal verification of D's memory model, all deque races, OS scheduling fairness, or native worker-start/join exceptions. Repeated close/park/admission tests and actual full native joins remain necessary. A faster candidate with a weakened lifetime guarantee is not acceptable.

## Test and benchmark policy

The [P18 fixture generator](../../../../tools/research/m1_p18_make_fixture.py) pins the already-qualified P13 kernel and driver Git blobs and reuses the **exact P16.2 adversarial race consumer** at blob `f158e14ef7a69cff1d2a5005090926794a5846ce`. It changes only module names and the compile-time import selected by `P18Grace`. The real original M0 source is imported for the `control` and `race-control` configurations; the generated P18 research source is imported for `grace` and `race-grace`.

[Compiler runner](../../../../tools/research/m1_p18_probe.sh) has:

1. Exact source hash and source-anchor **fail-closed** checks, plus a **negative test with deliberately modified original M0 source**;
2. Both original/grace versions of 135 adversarial scenarios per run: **last actual Worker TaskRef blocked until after close**, completion before close, and three producers racing close, across 1/2/4 workers × ingress 1/8/64; source checks and bounded timeouts catch deadlock;
3. Identical seed/shuffle/task output/checksum, per-wave and native join checks under DMD 2.111.0 and LDC 1.41.0, a bounded full **45-case target workload** (1/2/4 workers × five task sizes × three ingress sizes);
4. Additional **LDC assertions-on `-O3`** and full DUB **release**, including actual race and result-oracle checks. No CI threshold on performance.

The [independent CSV validator](../../../../tools/research/m1_p18_compare.py) requires exact workload/phase/order/seed/checksum equality and nonnegative, properly summed stage durations, while allowing parks/retries to vary as natural consequences of changed scheduling. It prints `grace/original` and comparative parks only as **CI diagnostics**.


**Recorded compiler evidence:** [GitHub Actions run #38469074496](https://github.com/alex-1974/concurrency-d/actions/runs/38469074496) **PASS** DMD and LDC, including source-drift negative checks, duplicated control/candidate race scenarios, all 45 small-native-profile configurations, LDC assertions-on optimized debug and LDC release. The earlier run [#38468584407](https://github.com/alex-1974/concurrency-d/actions/runs/38468584407) failed on an incorrect *CI CSV filename alias* for the optimized configuration; the candidate compiled and ran, and the alias was corrected without changing the scheduler semantics. Shared-CI timing ratios are deliberately non-gating.

## Native Dell-XPS protocol

[Foreground P18 XPS runner](../../../../tools/research/m1_p18_xps.sh) compares two **uninstrumented** LDC whole-release binaries with identical P13 2,048 × 3-wave TaskRefs, 45 configurations, four default sessions, two warm-ups and five measured shuffled sweeps. Within a session, both modes use the same seed and shuffled order. Their **whole-process** order alternates: original→grace and grace→original. The process CPU mask selects four Linux-allowed CPUs from distinct physical cores; **native workers are not pinned to specific cores**.

Before each session/process the P18 runner invokes the [P18-specific observational thermal audit](../../../../tools/research/m1_p18_thermal_audit.py). The default `P18_THERMAL_MODE=observe` records initial temperature (or missing sensor) as a flag and does **not** refuse admission solely for temperature. `P18_THERMAL_MODE=strict` optionally preserves the previous ≥95 °C/missing-sensor admission refusal; `P18_THERMAL_ALERT_C` changes the documented warning/strict threshold (default 95). The legacy `P18_ALLOW_HOT` override remains accepted and recorded for old commands but is not required in observation mode. Every process retains 500-ms sysfs-reported CPU frequency, package temperature and throttle-counter samples. The P18 reviewer flags high samples, counter changes, missing readings and sparse samples for inspection; it **does not issue an automatic performance verdict**. Monitoring is symmetric but cannot prove stable per-worker clocks or rule out unobserved transients. Evidence quality, run-order sensitivity, frequency drift and actual measured performance must still be reviewed. **The historical P17 gate/reviewer and their evidence remain unchanged.**

The runner also executes the source-identical real close/producer race consumers on the target **before** starting timing. Recorded benchmark data include normalized CSV, original raw logs, source/toolchain/affinity metadata, per-session comparison diagnostics and thermal/frequency traces. Both variants are *not* instrumented for steal events (adding such instrumentation would confound the throughput test); actual M0 `parkCount` and producer retry counts remain available.

Run in a separate worktree:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin research/m1-task-lifetime-boundaries
git worktree add --detach ../concurrency-d-p18 \
    origin/research/m1-task-lifetime-boundaries
cd ../concurrency-d-p18
bash tools/research/m1_p18_xps.sh \
    ldc2 /tmp/p18-xps-2026-10-13
```

Output is **`/tmp/p18-xps-2026-10-13.tar.gz`**. The script refuses to overwrite evidence. Review the manifest and DUB raw logs for local host/user/path identifiers before public publication. Partial and complete P18 XPS data have now been independently audited; the original raw archives are not committed to Git.

## Acceptance and rejection criteria

**KEEP as a candidate only** if the exact task oracle/close/park/admission/native joins pass in both compiler configurations and the independent XPS A/B control demonstrates a material throughput/latency benefit on its target workloads with thermal/frequency drift and process-order sensitivity explicitly assessed, without unacceptable regression for longer work, multi-worker contention or 1-worker idle power. Smaller `parkCount` is only secondary evidence.

**REJECT or DEFER** if one extra search reduces sleeps but increases latency, spin/search overhead, power or thermal load; if a lost wake, accepted/completed mismatch, failure-path ownership problem or worse latency appears; or if environmental observations and paired comparison controls cannot distinguish drift from a candidate effect. A one-worker grace may have no productive steal targets and can be intrinsically wasteful.

Any accepted scheduler work must still be separately proven for the existing unresolved native start/join exceptional lifecycle and public `@safe` borrowing before promotion. ADR-0001 remains **PROPOSED**, Issue #17 OPEN and PR #38 DRAFT. Do not change production M0, `develop` or grandfathered R0.5 PR #35.

## Actual native XPS evidence and disposition (2026-10-14)

- [October 13 partial run](evidence/xps-2026-10-13-partial-review.md): two complete A/B sessions, 450 measured pairs; thermally burdened and stopped by historical 98 °C preflight; **KEEP research / DEFER production**.
- [October 14 complete run](evidence/xps-2026-10-14-hot-review.md): four alternating A/B sessions; **900 valid matched measured pairs**, overall `grace/original waves_ns` median **0.935882**, P18 faster in 675/900 pairs, ingress-8 median **0.76538**. Sampled 72–83 °C across eight process traces, zero observed thermal throttle-counter increments. The historical invocation set `P18_ALLOW_HOT=1`; this does *not* mean an actual hot CPU was observed. With 512 iterations, 1- and 2-worker medians remain slightly slower. The finding is **research only**, not general speed/power/lifetime qualification.

The P18-only runner now separates **observed thermal attention flags** from **optional strict admission**. It does not reinterpret P17 research or retroactively alter the original October 14 benchmark harness. No production scheduling change or P19 is authorized by these results.

## P18 follow-up — long-task regression and zero-work CPU time (2026-10-14)

**Still research-only.** The [per-ingress 512-iteration audit](evidence/xps-2026-10-14-512-detail.md) finds modest 1/2-worker regressions in the complete October 14 source-pinned M0/P18 corpus, particularly sessions 2–4; session 1 sometimes favors P18. A new **`P18_PROFILE=long`** option exercises **128, 256, 512, 1024, 2048** iterations under the same 1/2/4 workers, ingress 8/64/256, TaskRef identity, producer semantics, checksums, LDC release build and four-session rotating paired protocol as the previous 45-case study. It is generated by the **same source-hash-pinned** P18 fixture generator and does not modify P13 or production M0.

To collect a new dedicated long-task native XPS record in a fresh detached research worktree:

```bash
P18_PROFILE=long P18_SESSIONS=4 P18_THERMAL_MODE=observe \
    bash tools/research/m1_p18_xps.sh ldc2 /tmp/p18-xps-long-YYYYMMDD
```

The **separate zero-work idle probe** uses the actual unmodified M0 or generated P18 worker pool, **admits zero TaskRefs**, waits for workers to settle, then collects process-wide C `clock()` CPU time and monotonic wall time over independent bounded sleep intervals with 1/2/4 workers. The metric is **CPU milliseconds per wall second**, plus park-count changes; it is **not** a direct measurement of watts, joules, core C-states, individual worker thread CPU, or GUI event-loop latency. There is no valid ratio when both absolute process CPU times are close to zero; the [strict per-session comparator](../../../../tools/research/m1_p18_idle_compare.py) reports paired *absolute* occupancy deltas and rejects tasks, mismatched idle intervals and incomplete worker/round coverage.

Run the source-pinned [idle XPS collector](../../../../tools/research/m1_p18_idle_xps.sh) from the same worktree:

```bash
P18_SESSIONS=4 P18_CPUSET=0,1,2,3 P18_IDLE_HOLD_MS=1000 \
    bash tools/research/m1_p18_idle_xps.sh ldc2 /tmp/p18-idle-xps-YYYYMMDD
```

It prebuilds both release binaries **before** measurements, alternates M0/P18 process order each session, logs original stdout and per-process temperature/frequency/throttle telemetry, retains exact compiler and source identity, and archives summaries and raw data. CI uses bounded debug-time smoke only; **CI clock values must not support performance claims**. Fully validate the host-collected archive before inferring if one additional yield/search changes sustained idle CPU time. Native Worker Thread join failures remain fail-stop, and there is still no generic `@safe TaskScope` claim.

**Decision remains DEFER for production.** The long-task follow-up and zero-task idle XPS archives are not yet available. No energy efficiency, power reduction, idle energy impact, or general throughput promise is established by these probes alone.

## Native XPS P18 long-work and idle follow-up — reviewed 2026-10-14

[Independent archive-based review](evidence/xps-2026-10-14-long-idle-review.md) covers two complete source-pinned LDC release artifacts from exact head `8efb55dd`: long-work SHA-256 `13134165acf1014cff5f64daf479fbb4f1d19ad745b90fc0e76dc4bf7b67c21f`; zero-work idle SHA-256 `42332be5efca76291fb8422b597b02154e844f0f445f35a552608fd92d27455f`. Both have four complete rotating-order A/B sessions, unchanged M0 control, no unsafe/partial CSV records; raw data are retained outside Git.

The 900 matched long-work release pairs have overall median `grace/M0 waves_ns = 1.0081`; 512-iteration medians are **1.0484/1.0494/1.0269** for 1/2/4 workers. 1024 and 2048 iterations are near parity, with large session-to-session variation. The 36 paired one-second settled zero-TaskRef idle intervals show no new park events and extremely small process CPU times (12–61 μs/second), insufficient to claim energy improvement or power parity. All sampled long/idle traces have zero observed package-throttle counter increment but varying temperatures (long 73–94 °C, idle 52–89 °C), **not** proof of stable worker clocks.

**Decision: KEEP P18 as narrow short-burst research; DEFER unconditional production promotion.** 512-work attribution, idle transients and actual power remain outside available evidence. Do not confuse these observations with TaskScope or native Thread.start/join lifetime proofs.


## P18 focused 512-work ABBA requalification — prepared 2026-10-14

The [source-pinned ABBA protocol](evidence/focus512-abba-protocol.md) tests the existing 512-iteration regression with **128 and 1024 iteration controls**, not a new scheduler. Its [dedicated XPS collector](../../../../tools/research/m1_p18_512_abba_xps.sh) compiles original M0 and P18 into immutable separate LDC release binaries before measurement and runs alternating ABBA/BAAB whole-process sequences. Four sessions × two nearby pairs × 27 cases × five measured rounds yield **1,080 strictly matched measured comparisons**. The existing checker enforces exact work/checksum/timing partition; the runner rejects incomplete 189-row process CSVs and records host/binary/environment/thermal provenance.

Original P13, source-locked M0, TaskRef and both scheduler algorithms remain unchanged. **DMD/LDC CI tests exercise the generated focus512 profile and LDC release; CI speed values are diagnostics only.** A new Dell-XPS native archive is necessary before any performance verdict from this protocol. Steal/re-search event probes, if justified by the result, must be collected separately from uninstrumented throughput.

**Current disposition: KEEP P18 for short-burst research; DEFER universal production promotion.** No accepted scope/lifetime or public `@safe` claim and no P19.

## P18 focused ABBA XPS result — reviewed 2026-10-14

The [complete independent Focus512 ABBA audit](evidence/xps-2026-10-14-focus512-abba-review.md) covers original archive SHA-256 `df4b1e1f60a0f95d4e7a6523f8af3e390e1138402fa1ab3e0718a77f84a61da6`, exact study source `0f85b1cb`, source-pinned unchanged M0, LDC 1.41.0 release, four sessions × ABBA/BAAB, 16 complete process CSVs and **1,080 matched measured pairs**, all exact-work, checksum, record-count and timing-conservation checks PASS.

The measured median `grace/M0 waves_ns` ratios are **128 iterations 0.9559**, **512 iterations 1.0119**, **1024 iterations 0.9829**. The **512 regression is small and session-dependent** (sessions 1–2 favor P18, sessions 3–4 favor M0). ABBA-pair-collapsed median at 512 is **1.0230**; the within-session/half/workload diagnostic contrast `R512/sqrt(R128*R1024)` has median **1.0472** but **is not an automatic normalization of the actual 512 regression**. Producer retry/park counts often fall despite slower 512 wave time.

Thermal attention: **session3-grace1** sampled 95 °C with a package thermal-throttle counter increase of +36; 15 other process traces have no observed increase. Excluding only the flagged half yields 512 median **1.0108** (315 pairs), while excluding all session 3 yields **0.9998**. Neither treatment makes the original full data thermally clean or proves cause. There is no stable clock, GUI-workload or power evidence.

**Decision: KEEP narrow research / DEFER universal production.** Next, separate exact-source *event-only* local/inbox/steal/search/retry/park counters from already-collected **uninstrumented** speed evidence; never rank instrumented timing. No production scheduler/API/lifetime change, P19 or merge from this result.


## Focus512 event-only trace follow-up — prepared 2026-10-14

The complete [ABBA native audit](evidence/xps-2026-10-14-focus512-abba-review.md) shows a median **512-iteration P18/M0 ratio of 1.0119**, versus **0.9559 at 128** and **0.9829 at 1024**, with strong session effects. One of sixteen original per-process thermal traces observed 95 °C and a package-throttle counter increment of +36. All 1,080 uninstrumented measured TaskRef pairs passed exact source/workload/result checks. No causal scheduler or power verdict follows.

The separate [event-only protocol](evidence/focus512-event-trace-protocol.md) adds **trace-control** and **trace-grace** research copies with exact-source/byte-identical source regeneration and independently generated pinned P13 TaskRef workloads. The single-writer, post-join counters separate local/inbox/steal recovery after the bounded grace yield from a failed second scan, drain exits, park attempts and actual Condition waits with/without outstanding tasks. Event conservation is checked both in the generator's trace consumer and by the strict CSV comparator.

The dedicated [native XPS collector](../../../../tools/research/m1_p18_512_trace_xps.sh) prebuilds both instrumented release binaries, alternates process order, retains per-process raw telemetry and archives original traces. **Instrumented elapsed times must never be ranked against the existing uninstrumented ABBA speed data.** A new XPS trace archive is needed before investigating event distributions; none has yet been supplied.

The production M0 scheduler and its original P18 one-retry candidate remain unchanged, and general production promotion is **DEFERRED**.

## XPS P18 event-only Focus512 audit — 2026-10-14

[Full independent native trace audit](evidence/xps-2026-10-14-focus512-event-trace-review.md): exact-source LDC 1.41.0 Dell-XPS event-only archive SHA-256 `14161de32b9119323994eab22c2e08097880c4e0238421eead93677130af8004`, source `6217bc62`, original M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. Four complete sessions, eight raw-process logs, **540 exact-work measured pairs** and 216 warm-up pairs, strict task/event conservation and 68–83 °C sampled with **no observed throttle-counter increments**. Original raw evidence remains outside public Git.

P18 counted **28,915 second search attempts**, recovering useful ingress/steal work **17,663 times (61.09%)**, encountering exhausted searches **10,426 times**, and exiting a drained pool **826 times**. Source-pinned M0/P18 instrumented arms recorded **62,021/143,847 failed foreign steal attempts** and **13,025/8,245 actual Condition.wait entries** respectively. These are **event counts, never elapsed-time qualification**.

Success by iteration is 68.8% / 54.5% / 50.9% for **128 / 512 / 1024**, so success rate alone does **not** explain the independent uninstrumented 512-work slowdown. At **four workers**, P18 actually parks *more often* in the event trace at 512 and 1024, and 1-worker 512 native ABBA slowdown cannot arise from foreign-steal overhead because there are zero foreign-steal attempts. No causal scheduler or energy conclusion has been established.

**Decision remains KEEP narrow research / DEFER unconditional production.** Suggested next isolated focus: one-worker producer/ingress path versus multiworker steal/park interactions, without using trace-arm wave timings as speed evidence. Production M0 and TaskRef semantics unchanged.
