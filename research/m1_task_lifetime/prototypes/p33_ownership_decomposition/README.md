# M1 P33 — Ownership-path decomposition (research design)

Date: 2026-10-15. Status: **protocol and source inspection only**. No native XPS P33 results, no compiler-qualified P33 implementation.

## Why this experiment is necessary

The native P31 record uses `submit_ns` across **producer construction, native Thread.start, task creation, repeated submission, and Thread.join** while four workers execute concurrently. This aggregate cannot identify producer-entry overhead, task allocation, the P29 generational manager lock or the M0 inbox. P32-C's direct borrowed-TaskRef M0 workload has different lifetime and task construction; it cannot settle P31's ownership overhead.

The actual P31 execution is implemented under `version(P31Benchmark)` in `research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d`. Its producer currently timestamps only GC allocation snapshots, not submission events. This source audit is based on research branch `ccad355ee86fd8bfb24bf9d4524eb92996cb79ed`.

## P33 experiment constraints

**Never** change production `source/`, P29 root/handle logic, native worker scheduler or admitted TaskRef callback behavior. Reuse a generated, drift-pinned research variant of the exact P31 consumer (only telemetry and an explicit start barrier); preserve the three original/deferred/managed arms and the fixed task, worker, ingress and retention dimensions.

1. Pre-create exactly the same producer objects before timing; keep the original `GC.collect()` placement and owner startup. Record `preparation_ns` separately from startup. **Do not move task creation into preparation**: doing so changes the per-task allocation semantics being examined.
2. Producers wait on an explicit barrier **before** their admission loops. Report `launch_to_barrier_ns` after all producers have reached it; report `release_to_last_producer_completion_ns` with a monotonic control-thread clock after release. An explicit barrier is an experimental intervention and therefore requires a matched no-barrier control.
3. Producer-local, thread-confined counters record `attempts`, `accepted`, `GC.allocatedInCurrentThread` delta and **separate sampled** timing around the wrapper call and task-construction boundaries. Collect only after all native producer joins, without a shared atomic hot-path counter. Timer overhead must be measured by a matched null-clock arm with identical sampling decisions. A wrapper interval is **not** an inbox lock measurement.
4. Time native worker close/join and (for managed P29) root reclamation **after producer completion**. Never infer worker quiescence from completion counters alone. Fail-stop on uncertain startup/join in keeping with P23–P29.
5. Run the same 1/2/4 producer sweep for `minimal`, `shared_atomic` and `sharded_atomic` work, fixed at 8,192 accepted tasks, four workers, ingress 128 and retention 1,024. Compare ownership modes only **within** a work kind. A single work kind suffices for the initial instrumentation correctness probe, but the final claim must cover the full matrix or be scoped.
6. Balanced process-level A/B ordering, at least three warm-up and nine measured paired rounds, XPS LDC release `-O3`, DMD 2.111.0 and LDC 1.41.0 CI correctness, raw artifacts, source hashes, CPU/governor metadata, SHA-256 receipt. No CI performance threshold.

## Validity gates

- Accepted and native-completed obligations equal task count for every arm; checked per-task execution/sums for atomic work and pool completion plus join for minimal work.
- Original and generated variants must agree on work dimensions and task callback *semantics*, not just accepted counts.
- All collected producer measurements must account for every attempted/accepted submission, and all retained owners must be reclaimed only after native join.
- Barrier and clock sampling overhead are independently reported; no subtraction of an assumed constant per call.
- `P31 submit_ns`, `P32 submit_ns` and eventual `P33 admission interval` are **different quantities**. Do not plot them as interchangeable throughput claims.

## Decision criteria

If P33 demonstrates substantial *wrapper* time but little user-visible retry, the next step is an external profiler of allocations, GC and OS scheduling before attributing the time to P29 manager locking. If P33 finds bottlenecks in manager transitions, proposed changes must preserve explicit process roots and generation/ABA protections. Only a semantics-matched uninstrumented candidate-versus-baseline native result can justify a production optimization.

**Current next implementation:** generated exact-P31 consumer and versioned DUB configuration, plus barrier correctness tests and paired null-clock controls. P33 is **not yet qualified**. Draft PR #38 and ADR-0001 stay unpromoted.

## Executable P33 and paired native capture

The generated P33 phase consumer now lives only as a temporary generated file at `p11_real_pool/consumer/p33_generational_owner.d`. It derives from the exact immutable P31 Git blob using `tools/research/m1_p33_make_phase.py`; the `p33-phases` and `p33-phases-optimized` DUB configurations are research-only. Every producer reaches an explicit semaphore start gate before entering the original per-task `p31Attempt` loop. The control remains the original unmodified P31 executable (same owner modes, TaskRecord work and retention); `tools/research/m1_p33_compare.py` enforces identical task count, work oracle and completion count across both.

Reproduction:

```bash
bash tools/research/m1_p33_probe.sh dmd
bash tools/research/m1_p33_probe.sh ldc2
bash tools/research/m1_p33_xps.sh
```

The native script alternates whole-process unchanged-P31 and start-gated-P33 order across three sessions, each containing three warm-up and nine measured rounds on LDC release `-O3`. It stores raw logs, CSV, validation, metadata, an archive and SHA-256 receipt outside the repository. **P33 native XPS results have not yet been supplied.** The new CI gate must pass before the runtime comparison is qualified.

This stage isolates the effect of a synchronization intervention, **not** pure thread-launch cost: the gated variant adds semaphore operations, thread-local clock reads and waiting; it still measures producer joins after barrier release. It does **not** yet separately timestamp each owned TaskRecord allocation or directly time the P29 manager lock. Those assertions require a subsequent narrower experiment and perturbation controls.
