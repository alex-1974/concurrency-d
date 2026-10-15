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


## P18 one-worker ingress/backpressure isolation — prepared 2026-10-14

The [dedicated single-worker protocol](evidence/single-worker-ingress-protocol.md) follows the independently verified [event-only trace](evidence/xps-2026-10-14-focus512-event-trace-review.md) without modifying M0 or P18. At 512 iterations the independent uninstrumented one-worker Focus512 ABBA corpus had median P18/M0 `waves_ns = 1.0119` (120 pairs), with substantial per-session variation. M0/P18 median per-measurement full-inbox retry counts were about 5,812/5,556; P18 event-only trace recorded about three extra worker searches per 512/one-worker measurement and **no foreign steals**. The retry and event counts are from different instrumented/non-instrumented processes; they do not prove an instruction-level cost.

The new generated-only `singleingress` P13 profile holds the **same one worker, TaskRef kernel, 2,048 tasks/wave and three waves** while comparing 128/512/1024 iterations under ingress capacities **8, 64, 256, 2048**. A 2048-slot inbox can accept a complete 2048-task wave without `SubmissionResult.full` regardless of worker progress. The [strict independent CSV checker](../../../../tools/research/m1_p18_single_ingress_check.py) validates that zero-retry property in every control and grace process. The [native A/B/B/A XPS collector](../../../../tools/research/m1_p18_512_single_ingress_xps.sh) prebuilds immutable release binaries, rotates process order, executes native close/producer races, and retains full workload-oracle and thermal evidence.

**No new native single-ingress archive has yet been collected.** Its capacity contrast is a test of the producer/worker backpressure interaction, not a claim to isolate the expense of one `Thread.yield()` or to control wall-clock frequency. A result favoring either hypothesis still requires matching uninstrumented performance evidence and source/lifetime correctness.

**Disposition unchanged: KEEP narrow research / DEFER general scheduler promotion.**

## Native XPS single-worker ingress/backpressure result — 2026-10-14

[Independent full archive audit](evidence/xps-2026-10-14-single-ingress-review.md) covers `p18-single-ingress-20261014-124632.tar.gz` SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`, source `e91c4eb9` and unchanged M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, LDC 1.41.0 release. Four complete ABBA/BAAB sessions yield **480 exact-work paired measurements** from 16 whole processes; all checksums, timing-stage/seed/order and original raw/CSV comparisons PASS. **Ingress 2048 has exactly zero producer `full` retries** in every control and P18 process and every round.

The **512-iteration uninstrumented P18/M0 median wave-time ratios**, by ingress **8/64/256/2048**, are **1.0627 / 1.0392 / 1.0539 / 0.9875**, 40 matched pairs per cell. At **128**: 0.9280/0.9273/0.9577/0.9567; at **1024**: 0.9913/1.0027/0.9941/1.0131. All four sessions regress at every tighter ingress, but the 2048 cell shifts between parity/slight regressions (S1/S2) and a P18 advantage (S3/S4). Collapsing adjacent ABBA halves retains the same finding. Full-inbox retries drop to zero at ingress 2048 while median parks remain 3 M0/0 P18.

Thermal samples are **sparse** (2/process), observed **78–88°C**, no observed throttle-counter increment; no fixed per-worker clock or energy claim. The intervention changes ingress capacity and **thus** backpressure, queue occupancy and interleavings together. It supports a producer/ingress interaction hypothesis, **not** an isolated cost proof for producer `Thread.yield()`.

**KEEP narrow P18 research / DEFER universal scheduler promotion**; next bounded study should separate producer retry/yield and ingress residency effects before any scheduler policy change. Historical research, production M0, `develop`, ADR, PR #35 unaffected.

## P18 producer/ingress event-only isolation — prepared 2026-10-14

The last [native one-worker ingress/backpressure A/B/B/A result](evidence/xps-2026-10-14-single-ingress-review.md), original archive SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`, showed **512 iteration P18/M0 `waves_ns` medians 1.0627/1.0392/1.0539/0.9875** at ingress **8/64/256/2048**. All 2,048-capacity processes had **zero full-inbox producer retries**. Ingress capacity also changes queue residency, contention and producer/worker interleavings; these native results support a backpressure/ingress *interaction*, not a measured `Thread.yield()` cost.

The [new source-pinned PI event protocol](evidence/single-worker-producer-ingress-trace-protocol.md) adds separate research **`pi-control` and `pi-grace`** DUB configurations without altering original M0/P18 or the P13 task/kernel source. The PI generator reproduces and verifies the existing exact-source trace variants, then counts admission attempts/accepted/full/closed, mutex-protected inbox take calls/empty outcomes/task totals, occupancy-after-accept histograms and peak, completion calls, generation/drain/announce calls and producer completion-poll yields. All inbox counters are mutated under the **existing** mutex and read only after join. A strict independent PI CSV validator requires complete TaskRef, ingress and grace-event conservation, including `submitFull == retries` and **`submitFull == 0` at ingress 2048**. DMD/LDC smoke, LDC release and intentionally corrupted-counter rejection are part of the [P18 research gate](../../../../tools/research/m1_p18_probe.sh).

The [separate native event collector](../../../../tools/research/m1_p18_pi_xps.sh) uses four alternating-order two-arm sessions, the same one-worker 12-case matrix and symmetric thermal telemetry. Successful output would contain **240 matched measured event pairs** (8 whole processes, 2 warm-ups + 5 measured rounds per 12 settings). This is **not** the prior **480-pair uninstrumented ABBA** dataset. **Event-trace wave times must never be used as performance evidence.** No new native PI archive is available yet.

**Decision: KEEP narrow P18 research / DEFER any general scheduler adoption**, awaiting interpretation of the independent PI event corpus and, if a specific candidate is later justified, new uninstrumented native speed/race qualification.

## Native P18 producer/ingress event-only XPS audit — 2026-10-14

[Complete independent native PI review](evidence/xps-2026-10-14-producer-ingress-event-review.md) covers archive `p18-pi-xps-20261014-132856.tar.gz`, SHA-256 `8c4b0c8b23cdd99f3c9feef1c3b38412b1c9a1d6c9cdee0d642d12081410e6f8`, source `841247c8`, unchanged M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a` and LDC 1.41.0 release. Four whole-process-order-alternating sessions, eight original raw logs/CSVs, 240 exact-work measured + 96 warm-up matched pairs and full inbox/grace/TaskRef event conservation all PASS. Ingress 2048 has **zero full-inbox retries** in both arms in all rounds.

**New mechanism insight, not a speed verdict:** At 512 iterations, ingress 8/64/256/2048 median M0 producer full retries are **6197.5/5990.5/5414.5/0** while M0 completion-poll yields become **49/227/834/6333**; P18 is very similar (**6184.5/5986.5/5402/0** full and **50/227/834/6317** poll). Combined producer yield counts remain roughly 6200–6330 per measurement: enlarging the queue **moves yields from retry to completion-wait**, rather than removing almost all yields. Both arms typically perform **768 batch claims, four empty takes and 772 generation reads** at 512; no systematic extra inbox-operation count is established. PI trace timers are instrumentation-confounded and **not used** to qualify speed. Existing uninstrumented ABBA performance ratios remain the timing evidence.

Thermal samples sparse (**two per process**, 83–86°C) with zero observed throttle-counter increments, no fixed frequency or power qualification. **KEEP narrow research / DEFER universal production**. Next possible bounded study: source-pinned submission-vs-completion wait phase overlap without modifying production scheduler.

## P18 single-worker phase-boundary overlap study — prepared 2026-10-14

The completed [native PI event-only audit](evidence/xps-2026-10-14-producer-ingress-event-review.md) showed a crucial ambiguity: at 512 iterations, increasing ingress capacity from 8 to 2048 **eliminated all producer-full retries but moved roughly six thousand producer yields from the submission/retry phase to the completion-polling phase**. Thus similar combined yield counts coexist with different [uninstrumented single-worker A/B/B/A](evidence/xps-2026-10-14-single-ingress-review.md) performance behavior. Event counts alone cannot attribute time or mutex contention.

The next [source-pinned phase-boundary protocol](evidence/single-worker-phase-boundary-protocol.md) uses **separate** generated `phase-control` and `phase-grace` modules. It does not modify original M0, P18 scheduler semantics, TaskRef layout or the locked P13 source. Only the generated research kernel records three non-overlapping intervals per wave: **before first admission**, **first-to-last admission**, **last admission-to-wave completion**, plus a residual accounting interval; one acquire snapshot per wave counts TaskRefs already completed when final admission returns. A strict independent [phase oracle](../../../../tools/research/m1_p18_phase_compare.py) verifies **sum of phase intervals == waves_ns**, all TaskRef/checksum/seed/order/stage identities, zero `full` retries at ingress ≥count, and rejects intentionally corrupted phase data. DMD/LDC correctness and LDC release smoke are required.

The independent [native phase XPS collector](../../../../tools/research/m1_p18_phase_xps.sh) prebuilds both phase-stamped release variants outside the time-measured processes and uses the existing ABBA/BAAB four-session, 1-worker, 128/512/1024-iteration × ingress 8/64/256/2048 scenario matrix (16 processes; **480 matched measured phase pairs**). It retains raw logs, source/binary/compiler hashes and symmetric temperature/frequency/throttle traces.

**Caveat:** Even a few boundary timestamps and one acquire snapshot per wave change runtime scheduling slightly. Therefore these are **phase-observation timings inside identical instrumented source copies**, NOT the historical fully uninstrumented scheduler speed evidence. The previous 480-pair original ABBA corpus remains the primary performance reference. No native phase XPS artifact has been received yet.

**Decision unchanged: KEEP narrowly scoped P18 research / DEFER universal production.** The measured objective is phase overlap (especially `completed_at_submit / (2048 × 3)`), not optimization by yield counts alone. No production source/`develop`, API/lifetime guarantee, P19 or unrelated branch change is justified.

## P18 native phase-boundary XPS audit — 2026-10-14

[Full independent native phase study](evidence/xps-2026-10-14-phase-boundary-review.md): original `p18-phase-xps-20261014-154309.tar.gz`, SHA-256 **`05a1de88e6c700908e78b3cb1e72f01f370203a6ac421fa22d72cb22476ffc6d`**, source `1c402593`, unchanged M0 `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, LDC 1.41.0 release. Four alternating ABBA/BAAB sessions, **16 complete processes**, **480/480 measured** and **192/192 warm-up exact paired** original-M0/P18 phase observations; original raw stdout/CSV, TaskRef/checksum and stage + phase conservation PASS, ingress 2048 full-inbox retries **0** throughout.

At **512 iterations**, median paired **P18−M0 submission-phase** differences (first to last TaskRef admission) at ingress **8/64/256/2048** are **+221/+258/+250/−28 µs**; corresponding **completion-wait** deltas are **−0.5/−1.3/−2.5/+13.6 µs**. The phase-stamped paired wave-time ratios are **1.0403/1.0458/1.0435/0.9951**, *not fully uninstrumented scheduler timing evidence*. The prior independent uninstrumented ABBA archive remains the proper speed qualification.

When the producer finishes admitting all **6,144** Tasks in three 512-iteration waves, median completed fractions are approximately **99.2%** at ingress 8, **96.5%** at 64, **87.1%** at 256, versus **2.8% M0 / 2.6% P18** at ingress 2048. Thus limited-capacity producer admission strongly overlaps worker execution; full-wave capacity shifts execution into post-submission completion waiting. **M0 and P18 overlap similarly at a fixed capacity**; the new finding localizes the 512-work phase difference to producer admission under backpressure but does **not** establish CPU instruction, mutex-wait, yield, thread migration or energy causality. Thermal traces sparse (2 samples/process), observed 78–90°C and no sampled throttle increments, not fixed-clock proof.

**Decision KEEP narrow P18 research / DEFER general production**. If research continues, separate producer/worker CPU scheduling and blocked/run time from ingress occupancy with externally observed thread events. No change to production M0, TaskRef lifetime, public API, `develop`, Issue #17, ADR PROPOSED, grandfathered PR #35 or Draft PR #38.


## P18 source-pinned external Linux CPU-scheduler trace — prepared 2026-10-14

The [independently audited XPS phase study](evidence/xps-2026-10-14-phase-boundary-review.md) found that with **512 iterations** and ingress **8/64/256**, P18's paired submission span was **+221/+258/+250 µs** relative to M0, but the post-submission wait differences were near zero. At ingress **2048**, the submission delta was **−28 µs** with **zero producer-full retries**. Those phase-stamped binaries were equally instrumented on both sides and are **not** the original uninstrumented benchmark. The underlying mechanism (CPU runnable delays, preemption, migration or lock contention) remains unknown.

The [next exact-source external Linux scheduling protocol](evidence/single-worker-external-perf-sched-protocol.md) adds generated-only `sched8` and `sched2048` profiles: one worker, exactly **512 kernel iterations**, 2,048 TaskRefs × 3 waves, keeping the same P13 kernel and unchanged M0/P18 worker scheduling. The [dedicated XPS collector](../../../../tools/research/m1_p18_sched_perf_xps.sh) prebuilds both release binaries, executes original native race/close fixtures, then records kernel `sched_switch`, `sched_wakeup` and `sched_migrate_task` tracepoints over selected CPUs while running one fixed workload per process. Four ABBA/BAAB sessions yield **384 matched measured TaskRef pairs**, 32 warm-up pairs, and separate `perf sched timehist` summaries for each target process. The [strict profile/TaskRef oracle](../../../../tools/research/m1_p18_sched_check.py) checks the full original task and result contract; CI validates the generated workloads on DMD/LDC debug and LDC release, and checks shell/Python syntax without relying on privileged tracepoints.

**Permissions and privacy:** Linux `perf` may not be usable under the XPS kernel's current security policy. The runner checks a real tracepoint capture first and **never runs `sudo`, rewrites `perf_event_paranoid`, or silently substitutes incomplete per-process sampling**. To check only permissions (no DUB builds): `P18_SCHED_PREFLIGHT_ONLY=1 bash tools/research/m1_p18_sched_perf_xps.sh ldc2 /tmp/p18-sched-preflight-UNIQUE`. The raw `perf.data` uses `perf record -a -C` and **may contain OTHER programs' and users' thread names** on those CPUs: never publish it without privacy review. Process-PID-filtered summaries and identification of the native worker TID must be audited before claiming per-thread results.

**Tracepoint instrumentation changes timing; perf-derived wall times are NOT a new M0/P18 speed benchmark.** The original uninstrumented source-pinned XPS ABBA corpus remains authoritative for performance. **No native perf scheduler evidence has been received yet.** P18 stays **KEEP narrow research / DEFER unconditional production**. No production, public API/lifetime, `develop`, R0.5 PR #35 or release-contract change.


## Linux XPS perf preflight denial and explicitly separate procfs fallback — 2026-10-14

The original CPU-scheduler `perf` trace was **not executed**: the [uploaded partial-archive capability review](evidence/xps-2026-10-14-perf-preflight-denied.md) documents SHA-256 `8231c655c8e415520998774776efe940a30e5506e467d084f8bb4fe2466fa356`, Linux 6.17.0-22, `perf 7.0.14`, `perf_event_paranoid=1`, and `No permissions to read /sys/kernel/tracing//events/sched/sched_switch`. Only preflight diagnostics were archived: **zero benchmark runs, zero perf events and no new scheduling speed evidence**. System-wide `perf record -a -C` requires a separate privilege scope, so changing one tracefs permission would not be a verified complete fix. The research automation never changes kernel permissions, mounts or sysctls.

A **separately user-opted-in** [read-only per-thread `/proc` protocol](evidence/single-worker-procfs-sched-protocol.md), [sampler](../../../../tools/research/m1_p18_sched_proc_sampler.py) and [XPS runner](../../../../tools/research/m1_p18_sched_proc_xps.sh) use only the benchmark's own PID/TIDs, with no `perf`, tracefs, system-wide collection, root or kernel changes. It can observe per-thread `schedstat` CPU runtime, context switches, last CPU and sometimes kernel migration counters; **Runqueue-wait requires `kernel.sched_schedstats=1` and is otherwise reported UNAVAILABLE, not zero**. Polling may miss short-lived worker threads, end-of-lifetime counters and migrations between samples, and perturbs scheduling itself. The new data MUST NOT be treated as equivalent to kernel sched_switch/wakeup events or as an uninstrumented speed comparison.

The user can first run `P18_PROC_PREFLIGHT_ONLY=1 bash tools/research/m1_p18_sched_proc_xps.sh ldc2 /tmp/not-used` in a pinned detached research worktree, without building. A full optional run is a **new experiment**: 4 sessions, 2 ingress profiles (`sched8`, `sched2048`), the same exact-source TaskRefs and alternating ABBA/BAAB M0/P18 schedule; expected **384 paired measured TaskRef comparisons**. **No native /proc observation has yet been received**. The original `perf` runner is preserved unchanged and never silently replaced.

**P18 disposition unchanged: KEEP narrow research / DEFER universal production**. Production source, `develop`, public lifetime contracts, ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38 and grandfathered PR #35 remain untouched.


## Native P18 `/proc` partial: collector JSON Path failure — 2026-10-14

The first user-provided optional `/proc` observation attempt stopped **after completing only the original-M0 `sched8` process**, not because the scheduler failed. [Independent partial-archive review](evidence/xps-2026-10-14-procfs-partial-json-failure.md), original archive SHA-256 `d51ff78705efd1c041a05feb1df481854ac8dd551a348a31e3a7265f00832a36`, source `0adf2e80`, unchanged M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`: both native race/close preflights PASS, first M0 run includes 2 complete warm-ups and 24 complete measured rounds with TaskRef/stage conservation, plus 592 sampled `/proc` rows over 38 transient TIDs. **No grace arm ran; no ABBA speed or scheduling conclusion is possible.**

The Python 3.14 observer failed at `json.dumps(metadata)` because retained command argv included a `pathlib.PosixPath` executable entry. The research-only fix converts it to `str(args.binary)`, and the self-test now executes the **same command builder** and JSON round-trip used by the real collector. The error is in the observer's provenance serialization, not D scheduling. **Preserve the raw partial outside Git**.

The XPS reports `kernel.sched_schedstats=0`; Runqueue-wait duration is **unavailable**, not zero. Even after fixing JSON, optional polling can observe only incomplete per-thread CPU, context-switch and migration samples and cannot establish runnable delay. No kernel settings or root privileges were changed.

**KEEP narrow research / DEFER unconditional production.** A fresh user-authorized observation run, if desired despite its reduced diagnostic scope, must use the new exact research commit and a new output path; never append to the partial archive or equate polling-instrumented elapsed time with original performance.

## Complete XPS single-worker `/proc` observation audit — 2026-10-14

The original [native full `/proc` diagnostic archive audit](evidence/xps-2026-10-14-procfs-full-review.md), source-pinned `4a0fd540`, SHA-256 `efdd7b82191604d4f28436ec97437fc3b7963aabe282dc7e07e08aee85905144`, original M0 pool blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, documents **32/32 complete processes**, four alternating ABBA/BAAB sessions, **384 matched measured + 32 warm-up TaskRef comparisons**, identical checksums and complete raw CSV, successful 324-case native producer/close race preflights for each arm. Both release variants were fixed before measurement. **All 2048-slot ingress rounds had zero producer-full retries.** Raw archive remains outside public Git due to PIDs/host metadata.

The now JSON-correct `/proc` polling observer collected **19,255** per-thread sample rows, observing **1,153** sequential non-main TID epochs, of which **315 were seen only once**, plus **504** disappearing/unreadable task attempts. Non-main TIDs are **not verified worker TIDs**; multi-epoch samples do not imply concurrently active workers. **All 32 hosts/process reports show `kernel.sched_schedstats=0`, so runnable/runqueue wait times are UNAVAILABLE (not zero).** At ingress 8, directly paired observed main-thread CPU-run delta P18−M0 has median **−23.49 ms** across eight paired processes but ranges **−83.26 to +32.41 ms** and changes substantially by session; at 2048 the median is **+4.38 ms** (range **−20.26 to +29.76 ms**). These are **incomplete observed sampling-window deltas**, not total worker CPU time, stable mechanism evidence, or uninstrumented speed. Sparse thermal snapshots 49–73°C, not constant clock/energy evidence.

**New qualified conclusion:** correctness and collection PASS, per-thread CPU/context-switch observation LIMITED, the runnable-delay hypothesis NOT QUALIFIED. Repeating the same polling diagnostic without new metrics is unlikely to resolve the causal question. Retain original independent uninstrumented XPS ABBA as the sole scheduler speed basis. **KEEP P18 narrow research / DEFER universal production**; no public `@safe TaskScope`, `develop`, ADR/issue state or other repository change.


## New P18 CPU-affinity intervention (1/2/4 physical cores) — prepared 2026-10-14

The [complete Dell XPS /proc diagnostic audit](evidence/xps-2026-10-14-procfs-full-review.md) confirmed native correctness and 384 matched TaskRef comparisons but could **not** measure producer runnable delay: **`kernel.sched_schedstats=0`**, transient worker epochs unverified and per-process observed CPU/context-switch deltas unstable across sessions. More equivalent sampling does not qualify the mechanism. The original perf kernel-event trace remains blocked by tracefs permission. No security settings should be changed implicitly.

Instead, the new [source-locked CPU-affinity intervention protocol](evidence/single-worker-cpu-affinity-protocol.md) tests whether the **512-work producer-full-backpressure P18 deficit** depends on availability of concurrent physical cores. It uses the **exact same unchanged prebuilt M0/P18 release binaries and P13 TaskRef kernel/producer loop**, with process-level Linux CPU masks `cpu1=0`, `cpu2=0,1`, `cpu4=0,1,2,3`. The [collector](../../../../tools/research/m1_p18_affinity_xps.sh) fails closed if these CPUs do not map to distinct physical cores or are outside taskset affinity; no additional tracepoint permission, thread instrumentation, `Thread.yield()` modification or production change is introduced.

Six balanced mask-order sessions, alternating ABBA/BAAB, execute 72 processes × 12 task/ingress cases × 2 warmups/5 measurements, expecting **2,160 directly matched measured pairs** and **864 warmup pairs**. Iterations 128/512/1024 and ingress 8/64/256/2048 preserve the previous control workloads. All variants undergo native close/producer race tests and exact-work TaskRef/checksum matching. The [independent affinity validator](../../../../tools/research/m1_p18_affinity_compare.py) verifies every whole-process file, no-full 2048, cross-mask checksum identity and reports session-wise paired raw wave-time ratios, not a CI speed threshold. Read-only thermal/frequency telemetry accompanies each process.

**Interpretation:** a changing regression across CPU masks would support a **CPU-availability/producer-worker-overlap interaction**; it would NOT prove the intrinsic cost of Yield, lock contention, runqueue delay or energy. Different masks also affect OS scheduling and turbo/frequency behavior. No native CPU-affinity XPS evidence has been received yet.

**KEEP P18 narrowly in research / DEFER general production**. Original M0/`source/`, `develop`, ADR-0001 PROPOSED, #17 OPEN, Draft PR #38, grandfathered PR #35 and all historical benchmark archives remain unchanged.

## Native one-/two-/four-core CPU affinity result — 2026-10-14

See the [complete independent Dell-XPS audit](evidence/xps-2026-10-14-cpu-affinity-review.md), original archive SHA-256 `5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`, original source `1a8b0eab30f8f7a46057f22b8cbead23375e7683`, M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. Six complete balanced CPU-mask sessions, **72/72 whole-release processes, 2,160 exact-work measured pairs / 864 warm-up pairs**, complete raw/CSV agreement and TaskRef/checksum/stage-time conservation PASS. Both arms are the same immutable binaries on all three masks, and 2048-inbox capacity has zero producer-full retries throughout.

**Major new result:** At 512 iterations, ingress 8, P18/M0 median paired uninstrumented `waves_ns` ratios by 1/2/4 physical-core masks are **0.121511 / 1.044167 / 1.036506**. Median M0 actual Condition parks **5899 / 3 / 3** compared with P18 **0 / 0 / 0**. Ingress 64/256 show the same qualitative reversal. With one core, P18's large advantage also holds at 128 and 1024 iterations; 512 is a special *modest penalty* only under available multi-core concurrency. This strongly supports **CPU availability × backpressure × actual parking interaction**, **not** an isolated per-wait, yield or lock cost. The one-core effect holds in all six sessions.

Two one-core M0 session-6 processes have sparse sampled package peaks **97 °C** (`HIGH_SAMPLE`), no observed throttle-count increases; dropping **the entire session 6** retains the one-core 512/ingress-8 ratio **0.11983**. Package/frequency samples do not establish constant clock, energy or transient-throttle absence. Raw host-containing archives remain outside Git; no new production policy is justified.

**KEEP narrow P18 research / DEFER production.** The new result is not a general application benchmark, fairness guarantee, public `@safe TaskScope` claim or universal single-core policy. Original `source/`, `develop`, ADR PROPOSED, Issue #17 OPEN, PR #38 DRAFT and grandfathered PR #35 unchanged.


## One-core M0 Condition.wait / ingress batch diagnostic — prepared 2026-10-15

The [independently qualified 1/2/4-core native XPS affinity study](evidence/xps-2026-10-14-cpu-affinity-review.md), original archive SHA-256 `5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1`, found at **512 iterations / ingress 8**, original M0 versus bounded P18 paired uninstrumented `waves_ns` ratio **0.121511 with one core**, but **1.044167 / 1.036506** with two/four distinct physical cores. M0 median original `park_count` was **5,899 under one core** versus typically **three under multiple cores**, while P18 mostly reported zero. This is an interaction, **not** measured sleep/wakeup duration: the production counter increments **before** invoking `Condition.wait()`.

The [next strictly bounded one-vs-four-core event-only protocol](evidence/single-core-condition-wait-batch-event-protocol.md) deliberately **reuses the previously qualified exact-source PI event-only M0/P18 research generators**, not another changed scheduler or producer yield policy. The [native runner](../../../../tools/research/m1_p18_pi_affinity_xps.sh) compares original P13 TaskRefs at Linux CPU masks `{0}` and `{0,1,2,3}`, enforcing distinct cores and exact effective masks, and collects **16 whole release-instrumented processes** over four alternating sessions: **480 exact-work matched measured event pairs** and **192 warm-up pairs**. The [independent validator](../../../../tools/research/m1_p18_pi_affinity_compare.py) enforces the complete one-worker 12-case ingress/iteration matrix, TaskRef/checksum/source equality across CPU masks, `parkWaits = parkNoOutstanding + parkWithOutstanding`, inbox batch and accepted/completed conservation, no producer-full retries at capacity 2048, grace search outcome conservation, and a corrupted-wait-counter negative case.

**Question:** When one-core M0 issues thousands of actual `Condition.wait` calls, does it claim work in many **small batches** rather than full ingress batches? Compare successful batch-claim counts, the mean `6144 / claims`, wait attempts vs actual wait calls, pending obligations at the wait point, producer retries/poll yields and P18 grace recoveries. **Do not** treat event counts, instrumentation-confounded wave time or a mutex access count as true blocked CPU duration, lock contention or proof of causality. If instrumenting the inbox changes the one-core pattern substantially, classify the trace as inconclusive. The preceding uninstrumented native 2,160-pair corpus remains the speed reference.

**Status: research-only design; no new native PI affinity archive received. KEEP P18 narrow research / DEFER production**, with unchanged M0 `source/`, `develop`, ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT, grandfathered PR #35 and historical raw evidence.


## Native P18 one-core Condition.wait/batch PI event audit — 2026-10-15

The [complete independent native event review](evidence/xps-2026-10-15-onecore-parking-batch-events-review.md), source `e4f461ce21dfa9e1fb751e976b2ce33d92908b84`, unchanged M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, original archive SHA-256 `74e69fb3fd4f2cf84244b07185afdc57ab2a7fbcf96197518c65caadfd1abeea` independently passes **16/16 PI event-only release processes**, complete original stdout/CSV, **480/480 matched measured + 192/192 warmup** same TaskRef work, complete inbox/park/grace conservation and 4/4 recorded 324-scenario native close/producer-race preflights. Event-traced binaries match the prior PI research source digest; no production scheduler change.

**Primary new result** at 512 iterations, ingress 8, **one CPU** (20 pairs): original M0 median **5,920 batch claims** to take 6,144 tasks (**1.04 tasks/claim**), **5,920 Condition.wait entries** and 5,921 empty inbox takes; P18 median **768 claims** (**8 tasks/claim**), **0 waits**, 769 empty takes, **768 grace searches = 767 ingress recoveries + 1 drain exit**. All four sessions replicate. **Four CPUs:** both variants median **768 eight-task claims**; M0 makes only **3 waits**, P18 none. Every archived `Condition.wait` call in 1,344 warmup/measured rows was classified `accepted == completed` immediately before the call, **not** necessarily a nonzero kernel blocking interval. At ingress 2048, zero full-inbox producer retries in both arms but M0 one-core still reports **147.5 median Wait calls**, so retry-on-full is not the whole mechanism. This repeats at 128/1024 iterations, not uniquely 512.

**This is event-only diagnostic evidence, NEVER a traced performance benchmark.** The preceding independent uninstrumented 2,160-pair native affinity archive remains the sole timing evidence: P18/M0 512/ingress8 ratio **0.121511/1.044167/1.036506** for 1/2/4 cores. Event counters are mutex-owned and perturb scheduling; `Condition.wait` counters do not measure actual block duration, fairness, energy or producer/worker wake timelines. Sparse temperature samples 71–88°C (49 observations total) with no observed throttle-count increase do not prove constant clocks.

**KEEP P18 narrow research; DEFER unconditional production**, preserve TaskRef/lifetime/no-public-`@safe` contracts, original `source/`, `develop`, ADR PROPOSED, Issue #17 OPEN, PR #38 DRAFT, grandfathered PR #35 and historical archives.


## Source-pinned producer success-Yield cadence intervention — prepared 2026-10-15

The [independent one-core inbox/parking event audit](evidence/xps-2026-10-15-onecore-parking-batch-events-review.md) identified a repeatable one-core M0 small-batch sequence (median **5,920 batch claims for 6,144 TaskRefs and 5,920 actual `Condition.wait` calls** at 512 iterations/ingress8) compared with P18's **768 full eight-Task batches and zero median waits**. Instrumented counter data are NOT speed evidence; the preceding independent 2,160-pair **uninstrumented** one/two/four-core XPS corpus remains the native speed baseline.

The next [explicitly different producer-workload protocol](evidence/producer-success-cadence-protocol.md) changes **only the generated, exact-P13-source-pinned research producer loop**: the successful-submission path may voluntarily `Thread.yield()` every **8** or **64** accepted TaskRefs, compared with a compiled-out **0** additional Yield arm. The existing producer retry-on-full, completion polling, original M0/P18 worker/queue algorithms, TaskRef execution, close/join and safety contract remain unchanged. For three waves × 2048 Tasks, deterministic additional success-phase Yields are **0 / 765 / 93** respectively. The new `cadence0` generated binary is *not asserted byte-identical* to the historical benchmark binary, even though its additional Yield site compiles out.

The [six-binary LDC release XPS collector](../../../../tools/research/m1_p18_cadence_xps.sh) compares **M0 versus P18 within each producer workload** at CPU masks **one core vs four distinct physical cores**, 128/512/1024 iterations and ingress **8 / 2048**, using six balanced pattern-order sessions and alternating ABBA/BAAB arm order. Expected **144 complete processes**, **2,160 directly paired measured TaskRef comparisons and 864 warm-up pairs**; thermal telemetry and native close/producer-race preflights are preserved. The [fail-closed independent cadence oracle](../../../../tools/research/m1_p18_cadence_compare.py) checks all exact-work rows, cross-cadence task/seed/checksum parity, the deterministic yield factor, phase/stage conservation, high-ingress no-full invariant and a corrupted-yield negative fixture. [DMD/LDC source-pinned smoke](../../../../tools/research/m1_p18_cadence_smoke.py) is required before XPS.

**Do not compare raw elapsed times between cadence0/8/64 as if they were semantically identical workloads:** the extra voluntary Yield is the deliberate independent variable, not an accepted scheduler optimization or portable energy/fairness improvement. No native producer-cadence archive has yet been provided. **KEEP narrow P18 research / DEFER unconditional production**; no `source/`, `develop`, ADR-0001 status, public `@safe TaskScope`, Issue #17, Draft PR #38 or grandfathered PR #35 change.


## Complete XPS producer-cadence intervention audit — 2026-10-15

The [independent full native audit](evidence/xps-2026-10-15-producer-cadence-review.md), original source `ab97b40b249970be26138e997fd4cb3c3ee54d2b`, original archive SHA-256 `503c51d4b1220b9acf8c084d34dc746cbcfc4d3567c617b62886884ec5ff7f0e`, original M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, LDC 1.41 release: **144/144 native complete processes**, 6048 exact scenario rows, **2160/2160 M0/P18 matched measured plus 864/864 warmup TaskRef comparisons** with full raw/CSV parity, six distinct prebuilt release binaries, deterministic extra success-phase Yields **0/765/93**, checksum/stage invariants, zero producer-full retries at ingress2048, balanced six-session mask/cadence/arm ordering, and **four retained 324-case native race/close PASS preflight logs**.

At **512 iterations / one CPU / ingress2048**, original M0's median actual `Condition.wait` calls change from **34 (zero additional producer Yields)** to **5977 (every 8 successful admissions)** or **4654.5 (every 64)**, even though **none** has a producer-full retry. P18 near-zero waits under every cadence. At ingress8 M0 keeps approximately 5900–6000 waits and P18 near zero. With **four CPUs** M0 has **3 wait calls** under all three cadences, P18 near zero. This directly supports a producer admission cadence × CPU availability × parking **interaction**, and proves that producer-full retries are not required for one-core M0's high wait-call mode. These are counters, NOT blocked-duration measurements; no current batch-claim counts were measured.

**CRITICAL THERMAL LIMIT:** This XPS corpus records **28 processes at ≥95°C, 15 with measured positive package throttle counter changes**, sampled package maximum **100°C** (277 sparse telemetry samples). In one-CPU cadence8 only **5 of 60** 512-work matched pairs have neither arm flagged at ≥95°C, so there is **NO adequate thermal qualification of the enormous one-core cadence8/64 native speed ratios**. Four-core/cadence0 512/ingress8 observed paired P18/M0 ratio **1.03177**, cadence8 **1.00063**, cadence64 **0.98656** inside distinct producer workloads; never infer a same-work production speedup *between cadences* or an accepted scheduler policy. The historical uninstrumented original-affinity archive stays separate. **KEEP P18 narrow research / DEFER production**, PR #38 DRAFT, ADR-0001 PROPOSED, Issue #17 OPEN, original `source/`, `develop`, grandfathered #35 unchanged.


## Source-pinned search-to-Condition park boundary safety gate — 2026-10-15

**Qualified outcome (CI PASS):** [Independent exact-source native boundary results](evidence/xps-2026-10-15-park-generation-boundary-result.md), source-locked `7209ab99` with original production M0 blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, DMD 2.111 debug + LDC 1.41 debug/**whole release**: **96/96 deterministic tests per M0/P18 binary and build**, plus source-mutation rejection. The bounded interleaving model reports 0 stale waits in 34 reachable M0 and 68 P18 abstract states; deleting generation **only in the model** finds one unsafe witness per mode. The first LDC-release research test harness was invalid because a mandatory submit was inside `assert` (removed by -release); all 16 assertion sites are now always-executed checks, **and the corrected native release gates PASS**. This is limited boundary correctness evidence, NOT performance or a formal full memory-model/liveness proof. No new thermally uncontrolled XPS benchmark run was needed.



The [park generation boundary correctness protocol](evidence/park-generation-boundary-qualification.md) addresses the worker's transition from **empty inbox/local/steal search to original `TaskInbox.parkUnlessChanged(observed)`**, rather than performing another heat-sensitive XPS speed run. Source inspection confirms **both original M0 and bounded P18 use the unchanged same `Mutex` / `Condition.wait` / generation-guard predicate**, with all successful publication, local work announcement, close and final closed completion transitions incrementing the generation while holding the inbox mutex. P18's only scheduling difference remains **one bounded additional `Thread.yield()` plus full search with a fresh ticket**; it does not replace or relax the final park gate.

The [exact-source native boundary fixture](../../../../tools/research/m1_p18_park_boundary_make_fixture.py) clones **only the pinned original M0 and the pinned generated P18 worker module**, appending identical *module-local research test entrypoints*, never touching `source/`. It checks (i) published work before the guard, (ii) work claimed by another worker between publication and guard, (iii) a new local-deque announcement, (iv) close+drain, (v) an actual `Condition.wait` awakened by announcement and (vi) an actual wait awakened by close, at Inbox capacities 1 and 8. These are bounded direct source-clone **correctness tests**, not benchmarks or proof of complete multi-worker liveness. All native rendezvous runs have external timeouts, and both variants are tested in DMD/LDC debug and LDC whole-release.

The [bounded abstract interleaving model](../../../../tools/research/m1_p18_park_boundary_model.py) independently source-checks the *exact original* mutex-owned park predicate and enumerates a finite set of worker captures/searches and up to three external events. Its deliberately broken **no-generation-check** model must find an unsafe stale-ticket interleaving, while the source-faithful predicate must not. This is **a bounded state-model regression, not a formal proof of the D memory model or OS scheduling/fairness**. Existing close-vs-last-completion, producer-vs-close, real TaskRef lifetime and multiworker steal/parking tests remain necessary.

The previously audited producer-cadence XPS archive reached **100°C and 15 observed package-throttling counter increases**. No new performance decision is possible from those thermal conditions. **KEEP P18 narrow research / DEFER unconditional production**, with original M0 `source/`, `develop`, public safety/lifetime API, ADR PROPOSED, Issue #17 OPEN, PR #38 DRAFT, R0.5 PR #35 and all previous native archives unchanged.

## Bounded multiworker producer progress gate — 2026-10-15

The [source-pinned M0/P18 coverage decision and verified progress result](evidence/multiworker-fairness-coverage-disposition-2026-10-15.md) adds one research-only `fairness/main.d` fixture. DUB configurations `fairness-control` and `fairness-grace` each exercise **16 bounded** (2/4 workers × 2/4 producers × ingress 8/64 × no-blocker/one-blocker) scenarios with 17 distinct TaskRefs, real semaphore-controlled blocking, progress of **all 16 runnable siblings while the blocker is held**, joined post-dispatch records and exactly-once oracles. The post-join worker-distribution observations are not fairness guarantees.

[Exact-source GitHub Actions #38704118550](https://github.com/alex-1974/concurrency-d/actions/runs/38704118550) **SUCCESS**, DMD 2.111.0 and LDC 1.41.0 debug; LDC additionally builds and runs both fixtures under whole-release. The qualifying source commit was `beb21c0f0d3f99ec752a3ab3fcccf3a4171745c4`. This is **not** another Dell-XPS performance/energy experiment and supplies no new p95/p99, multi-blocker liveness or starvation proof. Production `source/`, original M0 blob, external archives, ADR/Issue status and grandfathered PR #35 remain unchanged. **KEEP narrow P18 / DEFER unconditional production.**
