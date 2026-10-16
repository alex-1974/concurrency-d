# P38 — Condition notification and worker wake accounting

Research-only; **no production change**, no replacement of wake strategy.

## Starting evidence
P37 verified native XPS records show four-producer conditional-notify duration around 0.885–0.925 microseconds per accepted task and producer inbox-mutex wait around 0.513–0.533 microseconds. These **instrumented** durations include contention and timer overhead and cannot establish the cost of an actual OS wakeup.

## Source-pinned wake protocol
From `source/concurrency/internal/submission_pool.d` blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`:

- Producer `TaskInbox.trySubmit` increments `_generation` and signals `_changed.notify()` while holding `_mutex`.
- Worker captures `wakeGeneration()` **before** searching the inbox and foreign deques.
- Worker `parkUnlessChanged(observed)` takes the inbox mutex and evaluates `_generation == observed && _used == 0 && !(_closed && _completed == _accepted)` before waiting.
- `Condition.wait()` atomically releases the mutex during sleep and reacquires it on return. Spurious wakeups recheck the predicate.
- Local-deque publication uses `announceLocalWork()` with a generation increment and notify; `close()` and final completion use generation and notifyAll.
- Do not modify these transitions or infer one `notify` equals one sleeping worker awakened.

## P38 diagnostic design

Generate a research-only copy of the exact pinned pool (and P23 owner) and run fixed P31 workloads under independent null/timed arms. Preserve original generation, publish, wait, close, and reclamation order. Add **per-thread local** telemetry (producer publish / worker park sites), without a shared diagnostic lock:

1. Producer: `publishNotifyCalls`, elapsed notify interval, and an **under-lock snapshot** of `_parkCount` (historical cumulative; not current sleepers).
2. Worker: park predicate checks, actual `Condition.wait()` entries and returns, predicate rechecks, generation-changed returns and work availability. Attribute to workers, not producer threads.
3. Explicitly distinguish counters of notifications, waits, wake returns, and useful task dispatch. Correlate aggregate per-run counts only; do not pretend to pair individual notifications to wakes without trace IDs.
4. Separate worker accounting from the previously measured P37 producer inbox wait: it may contribute to producer contention.
5. Time optional worker wait return-to-work intervals **outside the inbox mutex**; never time blocking `wait()` itself as CPU duration or compare it to notification cost.
6. Preserve the no-allocation hot path where possible; validate added instrumentation overhead against null and original arms.

## Correctness and performance gates

Pinned-source assertions must guard original predicate, wake generation and GC-root-before-publication. Run DMD 2.111.0 and LDC 1.41.0 debug correctness with 27 profiles and at least three rounds. Require accepted/completed/executed/checksum agreement, no negative or overflowing counters, and independent producer attempt/admission accounting. Explicit race regressions: publish between generation capture and park; spurious wake; close while idle; local-deque announce; final completion notification. If no deterministic hooks can exercise a race, document it as unqualified instead of claiming coverage.

Then use the familiar rotated XPS three-arm protocol (3 sessions, 9 measured rounds, 8192 tasks, four workers; 1/2/4 producers, all three work modes). Capture raw logs, hashes, source pins and full receipts. Report **per-session and per-work-profile distributions**, not just pooled means, and distinguish clock granularity from true zero-cost phases.

## State

**P38 protocol/source anatomy only. No executable P38 instrumentation, compiler qualification or XPS data yet.** P37 remains the last natively measured slice. PR #38 Draft; ADR-0001 Proposed.

## Incremental P38 worker-count integration

The pool generator now anchors the worker-counter accessor inside `SubmissionWorkerPool` only (not the similarly named inbox method). The P38 owner exports the counter snapshot only after STOPPED and the native pool join; the P31-derived consumer aggregates per-worker `parkCalls`, `waitEntries`, and `waitReturns` after shutdown and asserts `waitEntries == waitReturns`. This is a **correctness-only** consumer slice: the values are not yet CSV columns, timed worker wake phases, or native evidence. Do not infer useful wakeups or notification correspondence from this invariant. DMD/LDC confirmation pending.

## P38 worker CSV gate — 2026-10-16

The P31-derived consumer now appends `park_calls`, `wait_entries`, and `wait_returns` to the P37 CSV. These are **post-join totals for instrumented workers**, zero by definition for M0. The paired validator checks `wait_entries == wait_returns <= park_calls` independently in both null/timed arms and delegates the unchanged task/phase/matrix invariants to the P37 validator on a projected CSV. This **does not** establish a causal correspondence between producer notifications and worker wakeups. Compiler confirmation for the CSV integration is pending.

## Native diagnostic protocol

`tools/research/m1_p38_xps.sh` is prepared for the same three rotated sessions and workload dimensions as P37. Its null/timed arms add joined worker park/return columns while the original remains the fixed P31 consumer. The paired validator checks P38 worker conservation plus P37 task/phase semantics; the P34 three-arm check guards matching task work across arms. Generated modules are cleaned on exit; the script refuses preexisting generated files and archives raw logs and checksums. **Not yet run on XPS.** Compiler qualification of this slice must pass before its observations can be used for analysis.
