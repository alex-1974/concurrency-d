# P18 — Multiworker, producer and fairness coverage disposition (2026-10-15)

**Decision: KEEP bounded P18 as research; DEFER universal production adoption.**
This is a read-only evidence/coverage review, **not a new native run, scheduler modification, speed result, or accepted fairness/liveness contract**. No work outside `concurrency-d`.

## Exact review baseline

- GitHub research branch `research/m1-task-lifetime-boundaries`, reviewed HEAD `0163f7b1cf7b8f43a86de26dcfda649d02296f82`, [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38) targeting `develop`.
- Unchanged production M0: `source/concurrency/internal/submission_pool.d`, Git **blob** `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a` (not an archive SHA-256).
- Exact original P13 task/driver blobs: `3852e8788757b62c5000ad55565359d6a20a78c1` / `723de6bf76ac838b10de4b3f1cb901315a5ced38`; original P16.2 close-race fixture `f158e14ef7a69cff1d2a5005090926794a5846ce`. `tools/research/m1_p18_make_fixture.py` pins these before producing M0 and P18 research-only copies.
- At the reviewed HEAD, [CI #38700528710](https://github.com/alex-1974/concurrency-d/actions/runs/38700528710) and [#38700522300](https://github.com/alex-1974/concurrency-d/actions/runs/38700522300) completed successfully with DMD 2.111.0 / LDC 1.41.0 DIP1000 jobs. New source-to-park tests had also qualified LDC whole-release native execution. This review does not rerun the gates.
- ADR-0001 remains **PROPOSED**; [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17) remains open. Grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35) was neither changed nor merged.

## Coverage inventory — what is actually established

| Requirement / question | Existing specific evidence | Limit / remaining gap |
|---|---|---|
| Search-to-park publication/announce/close boundary | [Source-pinned native and bounded model qualification](xps-2026-10-15-park-generation-boundary-result.md): 96 selected real-Condition tests per M0/P18 binary/build, model M0 34/P18 68 states, no stale wait witness; deliberate mutant has unsafe witnesses | Tests specific lock/Condition boundaries; no whole-memory-model, arbitrary scheduling or multiworker fairness proof |
| Multiworker exactly-once, close and accepted-obligation conservation | Source-pinned `p16_2_atomic_completion/race/main.d` replicated through `m1_p18_make_fixture.py`; `closedBeforeLastCompletion`, `completedBeforeClose`, `closeDuringProducers`; **1/2/4 workers × ingress 1/8/64**, with **three independent producer threads** in the close race, under DMD/LDC and LDC release via `m1_p18_probe.sh` | Producer threads may lose admission to concurrent close; **not** a sustained multi-producer fairness/throughput workload; no 8-worker coverage |
| Reused-pool throughput and worker scaling | Original P13 TaskRef kernel/driver reused in P18 research, 1/2/4 workers × task-size/ingress matrix, post-dispatch wave completion and final native join; [long-work native XPS review](xps-2026-10-14-long-idle-review.md) | **Single submitting producer**; identical synthetic integer tasks rather than mixed-duration producer bursts; no direct per-task latency or fairness distribution |
| Mixed producer cadence / one-core parking | [Producer cadence XPS audit](xps-2026-10-15-producer-cadence-review.md) and [one-core batch event audit](xps-2026-10-15-onecore-parking-batch-events-review.md) | Intentionally altered producer workload; mostly one worker; critical hot samples up to **100°C** and throttle increments invalidate precise one-core cadence-speed conclusions |
| Stable zero-work CPU | [Original idle XPS review](xps-2026-10-14-long-idle-review.md) samples settled one-second, 1/2/4-worker empty pools with zero tasks; no persistent extra parks | Not transient burst-boundary CPU consumption, electrical power, system C-states, multi-producer fairness, or worker-specific CPU time |
| Fairness under blocked/unequal tasks | The separate grandfathered R0.5 [PR #35](https://github.com/alex-1974/concurrency-d/pull/35) contains four-worker/producer and semaphore head-of-line investigations | Different research arm / owned-task workload, notification/storage variations; **cannot be silently transferred as P18/M0 fairness qualification** |

**Coverage conclusion:** existing M0/P18 tests already cover important **multiworker/multiproducer close-race safety**. Repeating those scenarios without a new observable invariant adds little. The significant gap is **progress distribution and transient CPU cost while real unequal tasks and multiple producers overlap**, not another generic lost-wakeup model.

## One bounded next research question (pre-registration; NOT yet run)

> With **unchanged source-pinned M0 versus one-retry P18**, do two/four concurrently publishing producers and two/four workers with a deliberately mixed set of fast and blocked tasks expose a material difference in **progress of runnable siblings while one worker is blocked**, tail start latency, per-worker work distribution or transient process CPU usage, despite equivalent exactly-once and native-join results?

**Minimal proposed research-only behavioral fixture (not implemented by this document):**

1. Keep the original source-pinned M0/P18 modules and the eight-byte **non-owning** `TaskRef`; records and captured referents stay address-stable/rooted through a successful final `closeAndJoin`. Do not offer a new `@safe` API.
2. One **explicitly released** semaphore-blocked task plus a small, bounded set of nonblocking distinct-ID siblings; **2 or 4** workers, **2 or 4** producers, inbox **8/64**, fixed exact work and seed/order controls. Place an externally controlled release deadline so a stuck fixture cannot leave indefinite blocked workers. A separate no-blocker control detects harness-induced stalls.
3. Record per-task admitted/started/returned state and worker index **after join**; no live shared counter reads without explicit synchronization. Preserve accepted = completed = sum of successful admissions, exactly-once IDs and no worker access after joined storage destruction. Record whether siblings start **before** blocker release as a diagnostic, **not** a blanket starvation-freedom contract (owner-deque head-of-line effects are already known).
4. Require DMD 2.111 / LDC 1.41 native debug and **executed** LDC whole release, deterministic oracle, source-drift negative guard, bounded subprocess watchdogs and successful real join. **Never put necessary state transitions exclusively inside D `assert`**; the prior release-mode harness omission is documented.
5. Event-only instrumentation may explain placement, but its wall time cannot qualify speed. Only if the correctness/progress gate exposes a consequential difference should a separately built, **uninstrumented**, matched native LDC A/B be considered, with a stated consumer/task mix and per-task p50/p95/p99. Treat distribution indices as observations, not fairness guarantees.
6. Thermally screen native speed work **before** execution and retain frequency, temperature and throttle evidence during all runs; require adequate coverage, abort/defer for insufficient controls or hot/throttled samples. Never request elevated trace privileges or run ad hoc hot-XPS profiling. Electrical energy requires separate qualified instrumentation; process CPU time alone is not watts.

**Falsification / stop decisions:** If the new probe only reproduces already-covered exactly-once/close behavior, stop (no extra variants). If no material progress or tail/CPU trade-off is established in thermally usable native results, retain P18 as research and defer policy change. Any safety failure blocks speed claims and requires preserving the exact failing source/toolchain/logs for root-cause analysis. An apparent throughput gain that weakens task ownership, join or close semantics is a failure, not an optimization.

## State at pre-registration (historical)

At the time of the initial review, no dedicated progress fixture or XPS run existed and the local environment lacked a D compiler. The pre-registration above remains the **prior** research question; it is not a later performance result.

## Subsequent bounded implementation and CI qualification — 2026-10-15

The research-only [multiworker progress fixture](../fairness/main.d) is implemented as **16 scenarios per original-M0/P18 arm**: worker counts 2/4, producer counts 2/4, ingress capacities 8/64 and a single semaphore-blocked task versus a no-blocker control. Each case publishes 17 distinct **non-owning** TaskRefs (one first, then 16 from concurrently released producer-start barriers), uses stable GC-backed records, and requires every runnable sibling's **post-dispatch return hook** before releasing the blocked worker. Each accepted record must have exactly one entry, execution and post-dispatch return; all producers and pool workers are joined before inspecting or reclaiming state. A successful one-blocker case necessarily exercised at least two distinct real worker Thread objects. The fixture reports worker identity distribution and park calls **after join**; they are diagnostics, not a fairness or timing contract.

The original `M0` implementation remains byte-identical with Git **blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**; P18 still adds only the source-pinned bounded extra search. The fixture is selected with DUB `fairness-control` / `fairness-grace` and gated by `tools/research/m1_p18_probe.sh` with an external native-process timeout. Required work is never hidden in `assert()`. Cleanup signals both producer and blocked-worker barriers before native join; uncertain start, semaphore or join failures are treated fail-stop rather than allowing borrowed records to unwind unsafely.

**Verified [exact-head workflow #38704118550](https://github.com/alex-1974/concurrency-d/actions/runs/38704118550): completed/SUCCESS at source commit `beb21c0f0d3f99ec752a3ab3fcccf3a4171745c4`.** Both `DIP1000 / dmd-2.111.0` and `DIP1000 / ldc-1.41.0` jobs PASS; the latter also **builds and executes** both P18 fairness modes under full LDC `release`. Each arm checks `P18_FAIRNESS_PASS scenarios=16`; old P01–P18 generation/race/TaskRef gates remain green. Initial integration failures (shell replacement text expansion and D's prohibition on `catch` directly inside `finally`) were corrected in research-only scripts/fixture; neither was a demonstrated scheduler failure.

**Precisely established:** with one deliberately blocked worker, in these **finite** cases the other worker(s) complete 16 runnable siblings before semaphore release; all 17 Tasks and native joins finish. **Not established:** time-bounded progress on arbitrary hosts, starvation-freedom, equal worker utilization, burst-blocker head-of-line behavior, sustained multiple blockers, per-task p50/p95/p99, M0-versus-P18 speed, transient worker CPU or power. The new fixture is **instrumented behavioral observation**, never a speed baseline, and no new Dell-XPS archive exists for it.

**Stop after this one correct bounded gate.** Do not create P19 or an adaptive production idle policy from its PASS. If future research needs a scheduling policy decision, first justify a narrow unequal-task, multi-producer native workload with separate uninstrumented LDC A/B, tail-latency and thermally controlled CPU/power evidence. Existing XPS cadence traces up to 100°C cannot qualify energy or a universal speedup.

**Decision: KEEP P18 as research / DEFER general production.**

Preserve all original raw-archive SHA-256 identities and source pins without rewriting original evidence. Leave `source/`, `develop`, `main`, ADR-0001 acceptance status, Issue #17, Draft PR #35 and all public lifetime promises unchanged. **KEEP P18 research / DEFER production.**
