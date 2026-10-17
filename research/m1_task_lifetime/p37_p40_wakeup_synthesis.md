# M1 wakeup and inbox evidence synthesis — P37–P40.1

Date: 2026-10-17. **Decision: research only; do not change production scheduler or ADR-0001 status.**

## Evidence provenance

Four independent native XPS experiments; each has three rotated sessions, 27 profiles, nine measured rounds per session, 8192 admitted/completed tasks per row and original/null/timed arms (729 measured rows per arm). All original, paired and three-arm validation receipts passed. Raw logs and sha256 receipts remain in their respective archived evidence, not reproduced in this document.

| Experiment | Evidence | SHA-256 prefix | Instrumentation |
|---|---|---|---|
| P37 | `prototypes/p37_inbox_publication/evidence/xps-2026-10-16-results.md` | `cc3030a5e440` | producer-side mutex, ring, notify timing |
| P38 | `prototypes/p38_worker_wakeup/evidence/xps-2026-10-17-results.md` | `db96c8b4ab58` | worker wait entries/returns |
| P39 | `prototypes/p39_notification_sites/evidence/xps-2026-10-17-results.md` | `03f853087edc` | four notify sites |
| P40.1 | `prototypes/p40_post_wait_outcomes/evidence/xps-2026-10-17-results.md` | `5fa641a5c698` | post-wait worker first outcomes |

P39/P40 XPS use LDC 1.42.0; baseline CI used LDC 1.41.0. Native worktrees recorded pre-existing dirty research artifacts, which must be preserved. Even when the workload is nominally the same, results from independent experiments are *not synchronized per-event observations*.

## What is established

1. **Producer publish path (P37).** At four producers, pooled timed medians per admitted task: 0.513–0.533 μs waiting for the inbox mutex, 0.0029–0.0035 μs for ring publication, and 0.885–0.925 μs inside `Condition.notify()`, depending on ownership mode. These are timestamped intervals with instrumentation overhead and exclude other publish work; they do not add up to true CPU cost or demonstrate an OS wakeup cost.
2. **Notification calls (P39).** Every accepted task emits one publish-site notify: exactly 8192 per row. Median local-work notify calls are about 1590–1655 in the null arm and 1858–1930 in timed across producer and ownership groups. Closing emits one `notifyAll` per owned row; the conditional final-completion `notifyAll` happens only in a minority of rows. A call count does not indicate how many workers were sleeping or activated.
3. **Worker waits (P38).** Real condition-wait entries equal returns after join in all tested owned rows; observed counts rise with producer count for this particular instrumented workload. Neither entry nor return alone proves kernel sleep or a useful notification.
4. **First outcome after wait (P40.1).** Per observed owned row, the sum of postLocal, postInbox, postSteal, postRepark, postDrained equals the number of wait returns. Aggregate null arm: 1,393,203 returns = 960,270 inbox + 67,085 steal + 363,957 repark + 1,891 drained. Timed arm: 2,198,328 returns = 1,207,671 inbox + 187,265 steal + 801,465 repark + 1,927 drained. `postLocal` is zero in the observed owned rows. `postRepark` conflates internal predicate-loop re-waits and a subsequent park attempt; `postInbox` counts a batch, not individual tasks.

## What is not established

- Neither a `notify()` call nor a `Condition.wait()` return identifies a corresponding OS-level wakeup. There is no per-event matching or syscall tracing.
- Timing probes themselves perturb producer/worker interleaving: P40 null/timed worker-return totals differ substantially, and so do P39 local-work notifications. Therefore do **not** combine measurements into a cross-probe synthetic cost model; do **not** claim that a fraction of notifies is redundant based on counts alone.
- Source-level one-to-one publish/notify is a behavioral property of the instrumented *current implementation*; batching or suppression changes liveness conditions and requires a distinct proof and exact semantic-equivalence gates.
- `notifyAll` at close/final completion must be preserved; its rarity in benchmarks is not evidence it is unnecessary.

## Prioritized, falsifiable hypotheses

| ID | Hypothesis | Evidence needed before any implementation decision | Safety and fairness gates |
|---|---|---|---|
| H1 | Producer-side notify bookkeeping / lock hold may dominate ring publication latency in highly contended profiles. | Measure full mutex-held interval and notify paths with low-overhead tracing or fixed-schedule microbench; replicate by producer count and work type. | No change to generation guard, root retention before publish, FIFO, or complete-worker shutdown. |
| H2 | One notification per task is more than necessary **when a worker is already active or an existing wake ticket suffices**; coalescing might reduce contention. | A *separate research-only* version of conditional notification, with controlled idle->publish and concurrent close races, plus no-missed-wake evidence; paired original/variant uninstrumented throughput and latency. | Prove no lost wakeup with generation/mutex invariants, no starvation, bounded ingress, exactly-once tasks, safe close/join. Never simply remove `notify()`. |
| H3 | First outcomes after a wait favor inbox claims, with steal rarer, while a significant fraction re-enters wait logic. | Split `postRepark` into internal predicate re-waits vs new park attempts, quantify branch outcomes via low-overhead worker-local counters, include idle and burst workloads. | Classification must conserve every wait return and not change worker search/park ordering. |
| H4 | Existing `notifyAll` on closure/final completion is needed for quiescence under contested shutdown despite rare observed triggers. | Deterministic schedules testing close-before-park, close-during-wait, completion-after-close, multiple waiting workers, with bounded completion. | Retain all close/final broadcasts absent a formal alternative proof; root/lifetime and orderly join invariant. |

## Next action: qualification before optimization

**P41 recommendation:** a narrow, deterministic research-only *wakeup classification* experiment that separates repeated `Condition.wait` returns within one park invocation from post-search re-parks and proves conservation across constructed event traces. Prefer deterministic synchronization barriers and controlled artificial returns rather than depending on flaky OS spurious-wakeup occurrence. No new public API, no production changes. Also maintain a strictly uninstrumented original control for performance comparisons.

Advance to scheduler optimizations only if a variant demonstrates equal semantics and repeatable native gains under original workload matrices and both DMD/LDC correctness. PR #38 remains Draft; ADR-0001 remains Proposed.
