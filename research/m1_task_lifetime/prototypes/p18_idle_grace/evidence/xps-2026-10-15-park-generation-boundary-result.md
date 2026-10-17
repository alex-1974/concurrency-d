# P18 — Native search-to-park boundary qualification result (2026-10-15)

**Disposition: SOURCE-BOUNDARY CORRECTNESS GATES PASS for the tested scenarios; PERFORMANCE MECHANISM and production decision remain UNRESOLVED.** No new native performance study is performed.

## Exact source and build provenance

- Research HEAD under test: **`7209ab99a2922dabec63038e9bcdf502d0e3fd48`**.
- Original production M0 `source/concurrency/internal/submission_pool.d` Git blob remains **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**. The source-pinned existing P18 bounded one-retry generator clones it without modifying `source/`.
- GitHub Actions full DIP1000/P18 research gate runs **[38700008043](https://github.com/alex-1974/concurrency-d/actions/runs/38700008043)** and **[38700012674](https://github.com/alex-1974/concurrency-d/actions/runs/38700012674)** both **SUCCESS**. They include DMD **2.111.0** and LDC **1.41.0** debug, plus original whole-release LDC native execution. Every test is executed from exact-source research-only M0 or P18 copies and the existing race/lifetime test suite.
- Qualifying code: [native source-boundary generator](../../../../tools/research/m1_p18_park_boundary_make_fixture.py), [bounded interleaving model](../../../../tools/research/m1_p18_park_boundary_model.py), [CI runner](../../../../tools/research/m1_p18_probe.sh), and [method/scope protocol](park-generation-boundary-qualification.md).

## Native checks with REAL mutex and Condition

The DMD and LDC research gate builds two separate original-M0 and P18 source-locked modules and runs **96 deterministic direct boundary checks per binary per build** (six scenarios × inbox capacities 1/8 × eight repetitions):

1. `trySubmit` after generation capture but before the atomic parking guard: no wait.
2. Same publication followed by `takeBatch` by a foreign worker: outstanding accepted TaskRef remains, inbox may be empty but stale generation precludes sleep.
3. `announceLocalWork()` increments generation with an otherwise empty inbox: no stale sleep.
4. `close()` after capture with no obligations: guard may not sleep when drained.
5. Actual native `Condition.wait`, observed only after its original mutex is released, then `announceLocalWork()` must wake the waiter.
6. Actual native `Condition.wait`, followed by `close()` and `notifyAll`, must complete and join.

All tested DMD/LDC debug and LDC whole-release executions **PASS**. Whole-release compiler invocation and native process execution are separate so a long compilation cannot be misreported as a lost Condition wakeup. The original source mutation (even just an appended comment) fails closed before generation. Existing unrelated native multiworker/producer/close/TaskRef adversarial checks remain mandatory.

## Bounded abstract interleaving model and negative control

The source-locking Python state model reads the EXACT original production Git blob and same 4-line generation/used/closed-completion park guard. It enumerates up to **three external state transitions** around original M0 capture/search/guard or P18 capture/search/second-capture/search/guard, assuming the final mutex-owned guard is atomic.

Both modes pass the fixed predicate:
- **M0:** 34 reachable abstract states, 4 permitted wait states, **0 stale wait states**.
- **P18:** 68 reachable abstract states, 4 permitted wait states, **0 stale wait states**.

Deleting only the **generation comparison in the abstract model** is an intentionally incorrect negative control: **1 unsafe wait state in each mode**. Example witnesses from the authoritative LDC CI log:

```text
M0: publish / foreign_take / capture / close / empty-scan / BUG:park-on-stale-state
P18: capture / empty-scan / publish / foreign_take /
     capture / close / empty-scan / BUG:park-on-stale-state
```

These counts are **bounded model reachable states**, NOT counts of real OS interleavings, actual kernel waits or fairness proofs. The model does not reproduce the complete D memory model, all druntime wakeup/notification orders, source-size generation wraparound, multi-worker queue lifecycle or arbitrary task failure/termination.

## Debug vs release regression discovered during qualification

The first research harness was **invalid for release execution**: necessary state transitions such as `inbox.trySubmit(...)` occurred **only inside `assert(...)`**. Optimized `-release` could omit those calls, causing a self-inflicted Wait and timeout. This was not a demonstrated M0/P18 scheduler wakeup defect.

The revised fixture **always evaluates** all 16 such checks through an explicit `requireParkBoundary(bool, detail)` helper; on failure it throws a useful error. It source-checks the expected number of sites. The following exact-commit DMD and LDC debug and LDC release gates **PASS**. No production code change followed from this instrumentation bug.

## Research interpretation

The source-faithful state machine and the selected native guard/notify tests **support that the original generation protocol protects against lost publication at the tested search-to-park boundary**. Since P18 uses exactly that same guard, the previously observed performance difference should NOT be described as a lost-wakeup correctness fix. The separately audited 2026-10-14/15 XPS evidence instead demonstrates **batch fragmentation and repeated actual Wait-ENTRY COUNT** differences under producer cadence / CPU availability. It does not quantify per-wait blocking duration, runqueue delay, idle fairness, power or energy. The latest XPS thermal study reached 100°C with positive throttle-count changes, so no new speed/energy conclusion is appropriate.

**KEEP P18 narrow research / DEFER unconditional production.** ADR-0001 PROPOSED; Issue #17 OPEN, Draft PR #38, original `source/`, `develop`, grandfathered R0.5 PR #35 and all previous XPS archives unchanged.
