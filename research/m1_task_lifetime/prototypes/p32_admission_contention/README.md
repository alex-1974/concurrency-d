# M1 P32 — M0 producer-admission mechanism isolation

Date: 2026-10-15. **P32-A evidence recorded; P32-B matched research consumer and paired correctness gate committed, CI still pending. No P32 native XPS measurement or causal verdict.**

Context: [P31's native XPS evidence](../p31_fixed_producer_scaling/evidence/xps-2026-10-15-results.md) observes substantial 1→2→4 producer submission-phase throughput loss at fixed 8,192 tasks, four workers, ingress 128, retention 1,024, including minimal task work. It does not time an individual admission or identify the cause. Issue #17 and Draft PR #38 remain open; ADR-0001 stays PROPOSED.

## Verified M0 source anatomy and possible confounders

The pinned production `source/concurrency/internal/submission_pool.d` implements an inbox synchronized by **one mutex**. The inbox protects publication, full/closed checks, batch take, accepted/completed accounting, wake generations, park protocol, and drain checks. Worker-local deque pop does **not** take that inbox mutex. The inbox's `trySubmit` is only one part of producer work: the P31 `p31Attempt` calls `OriginalExecutor.trySubmit`, `OwnedTaskExecutor.trySubmit`, or `GenerationalManager.publish`; those paths can allocate/retain records and perform extra validation. In P31, the submit interval also includes **producer Thread.start/join** and overlapping worker activity. A `full` retry may call `Thread.yield`, adding a distinct scheduling cost. A high contention hypothesis therefore does **not** identify one mutex as the cause.

Source pins, checked before all experiments:
- `source/concurrency/internal/owned_task.d` — `e74d6a73f956c562eab176e27687a47249f5815d`
- `source/concurrency/internal/submission_pool.d` — `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`

The source auditor `tools/research/m1_p32_source_audit.py` checks these immutable pins and expected admission/worker protocol constructs. It will **fail** on drift, not silently bless a new implementation. This is a review aid, not verification of a concurrency proof.

## Ordered mechanism qualification

**P32-A — classify existing P31 data without new execution.** Analyze `attempts - accepted`, separately for each producer/work/owner profile, to distinguish repeated failed admissions from one-successful-attempt cases. Compare `create_start_ns`, `submit_ns`, and `join_release_ns` within each matched round; do not reinterpret submission-phase time as time inside `TaskInbox.trySubmit`. P31 does not record per-attempt outcome categories or mutex waiting time. If `attempts == accepted`, it rules out user-level retries in that row, **not** mutex contention, allocations, or OS preemption.

**P32-B — equal-work instrumented versus untouched M0 control.** Produce the instrumentation only in a generated **research copy** of the pinned M0 inbox, never in `source/`. Same workload, execution path, completion checks and ownership lifetime as untouched M0. Record per-producer successful/failed admission counts and elapsed time on each attempt; partition time into **outside-lock** and **in-lock** portions, with monotonic timers on a sampled or bounded diagnostic path. Instrument worker `takeBatch`, `completeOne`, `wakeGeneration`, and `parkUnlessChanged` separately, including invocation and wait/wakeup counts. If timestamps themselves change contention, report that difference rather than extrapolating their cost away. Counters must not introduce new shared hot-path contention; use per-thread padded storage, aggregated only after a successful native join.

**P32-C — factorial controls.** Hold tasks/workers/ingress/retention and a single task-work kind constant, vary 1/2/4 producers. Use (a) unchanged scheduler/uninstrumented control, (b) instrumented copy of *the same* scheduler, and (c) control isolating producer-thread launch overhead outside the task submission interval. Use balanced/alternating A/B order, >=3 warm-up and >=9 measured paired rounds on XPS release LDC. Never compare different task kinds as semantically equal performance arms; retain P29 lifetime/GC-root/handle-generation semantics. Any M0 vs P29 timing difference must state that M0 has weaker independent ownership failure semantics.

**P32-D — conclude narrowly.** For each candidate mechanism report absolute medians, per-round paired ratios and raw ranges, instrumentation overhead and (if available) mutex wait-time distributions, task invariants, compiler/flags/CPU metadata, and source hashes. Do not claim a single cause from aggregate submission times, claim zero contention merely because no retries occurred, or promote P29 manager-lock changes on a noisy few-percent difference.

## Safety/reproducibility constraints

- Never modify production `source/` or pre-existing work (including Draft PR #35), and never merge the grandfathered Draft PR #38 to `develop` or `main`.
- Build generated research copies from pinned sources; clean up safely after every run, including failure.
- Exercise DMD 2.111.0 and LDC 1.41.0 correctness; optimized LDC `-O3` with assertions separately; CI runner wall-clock timings are diagnostics only.
- Native XPS artifacts must record original untouched and instrumented raw results, source hashes, metadata, archive SHA-256 and generated-code provenance.
- Fail-stop on uncertain native starts/joins; never declare worker quiescence based solely on a shutdown request.
- Any candidate changes to admission locking require separate proof that task records/GC roots remain live until native worker join, no lost wakeups and no ABA acceptance.

**P32-B implementation checkpoint (2026-10-15):** `consumer/main.d` and `dub.sdl` compare the actual pinned production `SubmissionWorkerPool` with the pre-existing P15 source-pinned timestamp overlay, using identical one-word TaskRef records, 1/2/4 producer counts, fixed workers/tasks/ingress, and native join-before-record-release. `tools/research/m1_p32_probe.sh` generates the P15 copy temporarily and runs debug/release DMD/LDC correctness comparisons; `tools/research/m1_p32_compare.py` checks record counts, task completion and lock-call conservation. The instrumentation deliberately changes time under the lock; resulting wait/hold observations are perturbed diagnostics, not uninstrumented timing ground truth. The original pool has weaker ownership/failure semantics than P29. The immediate CI run is [#38793687750](https://github.com/alex-1974/concurrency-d/actions/runs/38793687750), pending at the time of writing. **No CI PASS or native XPS measurement is claimed yet.** Full P32-C paired native sampling, separate producer-thread startup control and causal verdict remain outstanding.

## P32-C native capture prepared

`tools/research/m1_p32_xps.sh` now captures three paired process-level sessions (alternating control/timed order), each with three warm-up and nine measured rounds at 8,192 tasks, four workers, ingress 128, and 1/2/4 producers. It writes raw logs, CSV, per-session analyzer outputs, compiler/CPU/governor/source SHA metadata, an archive and a SHA-256 receipt outside the repository. The generated timed pool is derived from the pinned M0 source by the existing P15 generator and removed on exit. Run from a clean research checkout with `bash tools/research/m1_p32_xps.sh` and provide both `.tar.gz` and `.sha256` for verification.

**Limitation:** This harness keeps the producer launch/join within `submit_ns`; the separate launch-overhead control specified in P32-C is not yet implemented. Also, P15's timestamp operations inside the lock perturb the measured wait and hold intervals; timing alone cannot prove uninstrumented contention. The latest CI and native XPS capture must still be checked before drawing any performance conclusion.
