# P41 qualification ledger — 2026-10-17

**Research-only; conditional qualification pending the final CI run.** Relevant head at drafting: `89af296808b8903e11462f9e029701cdb69450c8`. No production scheduling change and no API promotion.

## Evidence matrix

| Layer | Source | Coverage | Limit |
|---|---|---|---|
| Bounded Python state exploration | `tools/research/m1_p41_protocol_model.py` | single producer, single worker, one task; generation, close, artificially repeated waits | abstract model, source text anchors only; no OS/GC proof |
| Six ordered abstract traces | `tools/research/m1_p41_ordered_scenarios.py` | close before/after ticket, during wait; publish before park/during wait; artificial re-waits | same bounded model |
| Native D condition fixture | `p41_condition_runtime.d` | real Mutex/Condition/Thread; close around wait and no-state-change notify | standalone fixture, not full pool |
| Pinned pool close/join | `consumer/p41_real_pool_close.d` | real four-worker startup and joined shutdown | no admitted tasks; park observation not a forced barrier |
| Controlled ticket/publish | `consumer/p41_ticket_barrier.d` | worker paused after actual `wakeGeneration()`, producer submits, releases worker; 12 once-only task cases | pause occurs before external work search, not inside kernel sleep |
| Publish after wait observation | `consumer/p41_wait_publish.d` | pool `parkCount()>0` before task submit; 12 once-only task cases | counter observation does not ensure worker remains asleep at publication |
| Stronger unchanged-state re-wait | `p41_condition_runtime.d` updated in `89af296` | broadcast without generation change must cause second `Condition.wait` entry, then close/join | native standalone; new CI result pending |

The earlier CI run `39035841493` fully passed DMD 2.111.0 / LDC 1.41.0 at `8b29c526a1de75c06d86c44162e6d68c653c5078`. The last P41 fixture enhancement requires a separate **new green run**, not inherited success.

## What we may conclude

The implementation has passed bounded generation/shutdown explorations and genuine D test cases around closing and publication. The source-pinned ticket barrier establishes a concrete scheduler-critical ordering and checks accepted, completed, executed counts. The updated standalone native fixture seeks to establish repeat-wait behavior after an unchanged-state notification.

## What we must not conclude

No exhaustive proof of all interleavings, no multi-worker starvation proof, no proof that arbitrary publish notifications can be omitted, and no benchmark demonstrating an optimization. Timing/notification results from P37–P40 are observational, instrumentation-sensitive. Multiple simultaneous producers, shutdown-final-completion races with accepted work and all-waiting workers remain important gaps.

## Exit criteria for P41 / entry criteria for P42

- Both compiler jobs for the final P41 enhancement green; if red, repair first.
- Verify no source/protocol drift and no production edits.
- Preserve test limits: real Condvar is not a deterministic scheduler, and source-level barrier placement is not OS wakeup tracing.
- For P42, implement only a *separate source-pinned research variant* against unchanged original, prove liveness first, then measure on the native XPS machine with matched workloads and repeated rotated arms.
- Keep close and final-completion `notifyAll`, generation predicate and task-lifetime/root contracts unchanged.

Decision: **P41 is a correctness baseline, not authorization to modify the production notification policy.** PR #38 remains Draft; ADR-0001 Proposed.
