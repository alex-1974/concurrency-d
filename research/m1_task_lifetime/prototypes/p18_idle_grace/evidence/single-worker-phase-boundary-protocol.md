# P18 — Phase-boundary single-worker A/B/B/A qualification (2026-10-14)

**State: experimental probe prepared; NO native XPS phase measurements yet.** No scheduler production change, lifetime/API promotion, or claim that phase-stamped binaries are the *original* uninstrumented reference.

## Motivation and original speed baseline

The previous [independent native PI event audit](xps-2026-10-14-producer-ingress-event-review.md), source `841247c8`, identifies two producer `Thread.yield()` phases in source-pinned P13:

1. **Admission retry:** `trySubmit` returns `full`; the producer retries after `Thread.yield()`.
2. **Completion polling:** after the final accepted TaskRef of a wave, the producer repeatedly checks the acquire counter and yields until the final completion.

At **512 iterations**, increasing ingress from **8 to 2048** moved median M0 yields from **6197.5 full + 49 poll** to **0 full + 6333 poll** per measurement (P18 similarly **6184.5 + 50** → **0 + 6317**). **Total producer yields remain of similar magnitude**, but the phase/location of waiting changes; neither yield duration nor scheduling-overlap was measured in that event-only corpus.

The *separate uninstrumented* [one-worker ABBA XPS performance study](xps-2026-10-14-single-ingress-review.md), archive SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`, found **512-iteration** paired P18/M0 `waves_ns` medians **1.0627/1.0392/1.0539/0.9875** across ingress **8/64/256/2048**. We need to determine **where the elapsed time is spent and how far worker execution overlaps producer submission**, rather than blindly optimizing Yield or queue capacity.

## Exact-source generated-only measurement

The [P18 phase generator](../../../../tools/research/m1_p18_phase_make_fixture.py) regenerates the **source-hash-pinned** P13 kernel, driver and race fixture using the existing reviewed generator, then modifies only the **generated research kernel and output CSV**. The original production M0 `source/` and original generated P18 candidate remain unchanged. DUB configurations `phase-control` / `phase-grace` compile both independently with **identical phase instrumentation**, native TaskRef kernel, one-worker pool, same submission loop and safety/lifetime behavior.

For **each wave**, the generated kernel records four sequential non-overlapping intervals:

| Phase column | Boundaries | Interpretation |
|---|---|---|
| `first_accept_ns` | Begin submission attempt → first accepted TaskRef | Startup/first admission, including any retry |
| `submit_span_ns` | First accepted TaskRef → immediately after the last TaskRef is accepted | Producer's admission span, including any full-retry Yield |
| `completion_wait_ns` | Last accepted TaskRef → wave-completion acquire counter reaches task count | Post-submission waiting and its completion-poll Yields |
| `phase_residual_ns` | Leftover from reported `waves_ns` | Outside/between the above measured wave intervals |

The [independent phase CSV validator](../../../../tools/research/m1_p18_phase_compare.py) requires **`first_accept_ns + submit_span_ns + completion_wait_ns + phase_residual_ns == waves_ns`** for each arm/measurement, all values nonnegative, exact matching source/workload/TaskRef checksums, unchanged stage conservation and zero `full` retries whenever capacity ≥ tasksPerWave. Errors fail closed. Synthetic negative tests corrupt the phase decomposition deliberately.

After the last accepted TaskRef of each wave, **one acquire read** samples the number of its Tasks that already completed their `afterExecution` callback. The summed `completed_at_submit` column ranges 0–`count × waves` and is a **direct overlap proxy**: it records work completed before the producer finishes submission. It is not a duration or a worker active-time measurement, and the small extra timestamp/acquire probes necessarily affect scheduling to some degree.

**Warning:** Unlike original P18 uninstrumented benchmarks, these phase-boundary variants have added timestamp and snapshot operations. They characterize phase placement **inside identical instrumented M0/P18 copies**, NOT the raw uninstrumented speed of the historical scheduler. Do **not** merge or numerically equate their whole-wave `waves_ns` with the prior uninstrumented 480-pair ABBA corpus. No energy/watt or per-thread CPU use is measured.

## Native XPS collection

The [dedicated phase XPS collector](../../../../tools/research/m1_p18_phase_xps.sh) reuses the strictly checked one-worker original-M0/P18 A/B/B/A protocol:

- Exact original M0 source blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`; pinned original P13 TaskRef kernel and driver.
- **One worker**, iterations **128/512/1024**, ingress capacity **8/64/256/2048**, 2,048 Tasks per wave × 3 waves; 12 configurations per process.
- Both phase-stamped LDC whole-release binaries **prebuilt before measurements**, with SHA-256 digests; original native close/producer race preflight for M0 and P18 required.
- Four sessions, process order **M0/P18/P18/M0** then **P18/M0/M0/P18**, 2 warm-ups and 5 measured rounds/cell; 16 processes; **480 matched measured phase pairs** plus 192 warm-up pairs. Adjacent pairs use identical round, order, random seed, TaskRef checksum and stage/phase decompositions.
- Original raw stdout CSV, symmetric sysfs-reported frequency/package temperature/throttle counters (500-ms nominal samples), CPU process affinity and host/compiler/binary provenance retained. Sparse thermal samples and lack of individual producer/worker pinning must be stated explicitly.

Run from a **fresh detached research worktree at the exact approved head**, not from `develop`:

```bash
P18_PHASE_SESSIONS=4 P18_PHASE_CPUSET=0,1,2,3 \
    bash tools/research/m1_p18_phase_xps.sh ldc2 \
    /tmp/p18-phase-xps-YYYYMMDD
```

The collector refuses to overwrite archives, produces a checksummed TAR.GZ, and reports no speed qualification from phase-stamped binaries. Retain incomplete artifacts as diagnostic only; review host/path identifiers before publishing. DMD and LDC CI smoke plus LDC whole-release checks must succeed before full native XPS execution.

## Interpretation and next gate

Compare first-admission, submission-span and completion-wait intervals by **task iterations, ingress, session and A/B/B/A half**. The *primary new overlap measure* is `completed_at_submit / (2048 × 3)`, not total Yields. Check whether the submission time fraction and already-completed fraction change with capacity **differently at 512** than at 128/1024. Keep each interval's absolute distribution and the within-session P18/M0 comparisons; do not normalize away a real difference via a control workload.

If a reproducible phase effect exists, a future *bounded* producer retry/queue scheduling candidate may be investigated, but only with **fresh independent uninstrumented** native A/B throughput, correctness, race/close/join gates and real thermal evidence. No scheduler policy change or general speed, energy, fairness or `@safe TaskScope` promise follows from the phase probe.

**Disposition still KEEP P18 narrow research / DEFER universal production adoption.** ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT, `source/`, `develop` and grandfathered R0.5 PR #35 untouched.
