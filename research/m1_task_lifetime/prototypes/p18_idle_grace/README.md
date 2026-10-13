# P18 — One bounded idle-search retry before parking (research only)

**Research date:** 2026-10-13  
**Scope:** one scheduling transition, not a new executor family.  
**Branch:** `research/m1-task-lifetime-boundaries`, [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Status:** generated exact-source candidate and original-M0 control, DMD/LDC CI qualification in progress; **no native P18 XPS performance evidence yet**. Do not promote this candidate to production.

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

## Native Dell-XPS protocol

[Foreground P18 XPS runner](../../../../tools/research/m1_p18_xps.sh) compares two **uninstrumented** LDC whole-release binaries with identical P13 2,048 × 3-wave TaskRefs, 45 configurations, four default sessions, two warm-ups and five measured shuffled sweeps. Within a session, both modes use the same seed and shuffled order. Their **whole-process** order alternates: original→grace and grace→original. The process CPU mask selects four Linux-allowed CPUs from distinct physical cores; **native workers are not pinned to specific cores**.

Before each session/process the runner uses the existing [read-only P17 sysfs telemetry](../../../../tools/research/m1_p17_telemetry.py) to reject initial package temperatures ≥95°C or missing package sensors (unless `P18_ALLOW_HOT=1` is explicitly set, marking results **diagnostic only**). For every process it logs separate 500-ms reported CPU frequency, package temperature and readable thermal-throttle count samples, then [summarizes per-process thermal screening](../../../../tools/research/m1_p17_thermal_review.py). Monitor work is applied symmetrically to both versions. A screening pass is **not proof of stable per-worker clock frequency**, and an incremented throttle counter or hot/missing sensor is **NO-GO for a production performance verdict**.

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

Output is **`/tmp/p18-xps-2026-10-13.tar.gz`**. The script refuses to overwrite evidence. Review the manifest and DUB raw logs for local host/user/path identifiers before public publication. **There are no P18 native data yet.**

## Acceptance and rejection criteria

**KEEP as a candidate only** if the exact task oracle/close/park/admission/native joins pass in both compiler configurations and the independent XPS A/B control demonstrates a material throughput/latency benefit on its target workloads under adequate thermal headroom, without unacceptable regression for longer work, multi-worker contention or 1-worker idle power. Smaller `parkCount` is only secondary evidence.

**REJECT or DEFER** if one extra search reduces sleeps but increases latency, spin/search overhead, power or thermal load; if a lost wake, accepted/completed mismatch, failure-path ownership problem or worse latency appears; or if XPS thermal/frequency screening is insufficient. A one-worker grace may have no productive steal targets and can be intrinsically wasteful.

Any accepted scheduler work must still be separately proven for the existing unresolved native start/join exceptional lifecycle and public `@safe` borrowing before promotion. ADR-0001 remains **PROPOSED**, Issue #17 OPEN and PR #38 DRAFT. Do not change production M0, `develop` or grandfathered R0.5 PR #35.
