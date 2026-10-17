# P36 — Separate executor-lock work from mutex contention

2026-10-16. **Active research, no production change.**

## Starting evidence

P35 native XPS (3 sessions, 729 measured rows per arm) shows that the instrumented owner lock at 4 producers has approximately 15 µs wait and 4.4 µs hold per attempt, for both deferred and managed owners. The Timed arm itself increases submission interval by roughly 13% versus Null in the four-producer profiles. Consequently, *subtracting instrumented durations from original P31 is invalid*. The held section encompasses at least capacity/reap, three source-level constructions, retention, and nested inbox submission. Allocation expression count is not allocator call count.

## P36 question and falsifiable hypotheses

What part of the **held critical section** is spent in each of (A) capacity/reap, (B) result-cell/handle/node construction, (C) retention append and root installation, and (D) nested inbox submission and rollback? Does an instrumentation-controlled candidate that prepares only safe-to-prepare state before admission shorten the **uninstrumented** 2/4-producer wall-clock interval without increasing unaccepted allocations or compromising lifecycle semantics?

The first experiment is **observational only**. It must not relocate allocations yet.

## Source and lifetime boundary

Immutable production source pins: owned_task `e74d6a73f956c562eab176e27687a47249f5815d`; inbox `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`; P31 consumer `d19405f2ef0f8d7159978174c1a919ed6d66764f`. Generate P23 research owner and P35 TLS owner as independent pinned upstreams. Refuse source-anchor drift and do not modify `source/`.

The GC root must exist **before** a worker can claim a task. Rejected submissions must clear the GC-scanned tail. Do not manufacture work or allocate on the backpressure path in a purported semantics-preserving performance candidate. Do not change P29 manager's before/after lock phases or weaken native join and fail-stop behavior.

## Proposed diagnostic measurements (producer TLS only)

Under the existing owner mutex, capture independently the elapsed intervals for:
- budget check and any full-budget reclaim (retain separate cold-path event counter; otherwise the mean hides O(capacity) behavior);
- three task-object construction expressions as one phase initially (not three allocator invocations);
- retention append / strong-root publication;
- inbox trySubmit plus any rollback.

Aggregate per producer **after** its thread finishes, and include the sum of recorded events and successful/rejected attempts in the CSV. Avoid creating shared hot-path statistics. Keep all original control flow; a D `scope(exit)` intended for lock release must be placed at the synchronized-block scope, not inside a nested version block (P35 regression).

Arms: untouched P31; a null overlay with exactly corresponding thread-local counters but **no clocks**; a timed overlay with clocks at each boundary. Run both DMD 2.111 and LDC 1.41 correctness before optimized native XPS. Rotate arms across 3 native sessions and preserve raw CSV, source hashes, CPU/environment data and full 27-cell work/producer/owner matrix. Report intervals as diagnostics only.

## Decision gates

1. **Source gate:** exact pins and control-flow order, including both retention-budget checks and task-root-before-publication.
2. **Correctness gate:** full worker completion and checksum, producer-local event conservation, null clocks zero, timing nonnegative, no task-lifetime weakening.
3. **Performance gate:** distinguish null/timed observer effects; a faster non-instrumented candidate must be compared directly against original P31 under semantically identical backpressure and failure behavior.
4. **Stop:** do not promote an optimization based only on instrumented critical-path timing, or if unaccepted attempts acquire new allocation work.

**State (2026-10-16):** P36 protocol, source audit, generated producer-local four-phase owner and consumer, null/timed DUB configurations, paired CSV validator and CI compiler step are committed. **DMD/LDC correctness results pending**; no valid P36 native XPS timings or optimization candidate yet. Budget/reap events are counted separately; capacity timing currently records the successful-admission interval, not each rejected path. ADR-0001 Proposed; PR #38 Draft.

## Validator correction (2026-10-16)

The intermittent `P36 call conservation failure` was an analyzer defect, **not evidence of extra owner calls**. The old comparison used the *timed arm's* `attempts` for both null and timed arms; independently scheduled benchmark processes can legitimately have different backpressure retry counts. Each arm must instead satisfy `owner_calls == attempts` (except M0, which has zero instrumented owner calls) against **its own** attempts. Task count/completion/checksum and fixed work dimensions remain matched across arms. A producer-local runtime `check` independently enforces this invariant. The fix must still pass both DMD and LDC CI before P36 is declared qualified.
