# P37 — Nested inbox publication anatomy

2026-10-16. Research-only; no production or API change.

## P36 evidence

Verified XPS P36 phase evidence is recorded in `../p36_owned_critical_phases/evidence/xps-2026-10-16-results.md`. At four producers, the instrumented `_pool.trySubmit(node.reference())` interval accounts for ~67–68% of the sum of four observed owner phases. This is not a causal attribution of original wall-clock time: timestamps perturb the nested critical section, and session 3 had substantial original-arm drift.

## Exact source anatomy

`source/concurrency/internal/submission_pool.d` Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a` defines `SubmissionWorkerPool.trySubmit(TaskRef)` as a direct call to `_inbox.trySubmit(task)`. `TaskInbox.trySubmit` rejects null refs before locking, enters `synchronized(_mutex)`, rejects closed/full, calculates a ring-buffer tail, writes `TaskRef`, increments `_used`, `_accepted`, `_generation`, signals `_changed.notify()`, and returns accepted. Separately, `TaskInbox.hasCapacity()` acquires this same mutex and is invoked by `OwnedTaskExecutor` *before* allocation, while holding its distinct owner mutex. The worker `takeBatch()`, `wakeGeneration()`, `completeOne()`, and `parkUnlessChanged()` also use the inbox mutex.

## P37 hypotheses and design constraints

Measure producer-local nested inbox mutex *wait*, *validation*, *queue-and-counters*, and *condition notification* intervals. Distinguish successful admissions from `full`/`closed` rejection and report failed-attempt counts. Preserve identical control-flow ordering, lock/unlock boundaries, ring index arithmetic, generation and wake predicate, worker accounting, and GC-root-before-publication. No new locks, hot-path global atomics, unbounded waits, synthetic allocations, or production modifications.

Generate a source-pinned **research-only copy** of the pool and route the generated P36 owner to it. Production pins must match; do not modify `source/`. The validation gate includes DMD 2.111.0 and LDC 1.41.0 correctness, per-arm attempt conservation, every accepted/completed task and checksum, plus deterministic full/closed and worker-wakeup tests. Compare original P31, P37 null and P37 timed with 3 rotated XPS sessions, 9 measurement rounds, all 27 dimensions, 8192 tasks, 4 workers, ingress 128, retained 1024. Preserve hashes, raw logs, CSV, validation receipts, environment snapshots and archive SHA-256.

## Interpretation

The capacity precheck and nested publication both acquire the inbox mutex but eliminating either lock is **not** yet justified. Removing the precheck can allocate on rejected submissions, violating the contract P36 preserved. A worker may drain the queue between capacity check and publication, and the wake-generation predicate must remain tied to the same inbox mutex. Timed phase sums may omit entry/exit accounting and must not be subtracted from original uninstrumented time.

**Stage:** source anatomy and experiment contract, executable P37 overlay and native results not yet qualified. PR #38 Draft; ADR-0001 Proposed.

## Executable P37 slice (2026-10-16)

A source-pinned Research inbox and owner now feed a P31-derived consumer. Producer-local counters separately report inbox mutex wait, ring publication, and `notify()` duration. Null/timed configurations and a full-profile DMD/LDC debug correctness gate are committed. Clock sums are diagnostic only and omit some validation/release costs. Each arm checks its own retry attempts; null clocks must remain zero. Compiler and native XPS qualification remain pending; production source is unchanged.

## Clock-resolution finding (2026-10-16)

DMD 2.111.0 produced one valid 384-admission profile with inbox wait 74800 ns, ring queue 0 ns, and notify 955100 ns. The queue block is only a few primitive operations, so elapsed ticks can quantize to zero even when 384 tasks have been accepted. Zero `inbox_queue_ns` is therefore reported as **unresolved**, not as zero queue cost or a missing execution. The paired analyzer still requires positive wait and notification durations in owned modes, zero null-arm clocks, matched task semantics, and inbox calls equal to admissions. Further queue-cost attribution needs a clock-resolution-aware or amortized microprobe.

## Native XPS protocol

Run `bash tools/research/m1_p37_xps.sh` on the XPS from the repository root after updating the research branch. Default compiler: `ldc2` (override via `P37_COMPILER`); default output: a timestamped directory under `~/Downloads`, plus `.tar.gz` and `.sha256`. The script refuses to overwrite existing generated source or output, cleans generated D modules, and executes 3 rotated sessions (`original/null/timed`, `null/timed/original`, `timed/original/null`) with 9 measured rounds, 3 warmups, 8192 tasks, four workers, ingress 128 and retained 1024. It captures compiler/CPU/git data, generated hashes, raw logs, CSV, and per-session P31/P37/P34 validators. Upload both archive and receipt for analysis. This is diagnostic-only: clock resolution can produce zero queue intervals and the instrumentation affects contention. Native results remain pending.
