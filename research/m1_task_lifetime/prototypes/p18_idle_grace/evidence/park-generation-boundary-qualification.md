# P18 — Source-pinned generation-to-Condition parking boundary qualification (2026-10-15)

**Status: research-only correctness qualification; no new native XPS speed experiment.**
**Original scheduler and producer unchanged. P18 remains KEEP narrow research / DEFER general production.**

## Why this gate now

Independent 2026-10-14/15 Dell XPS evidence found that the original M0 under one physical CPU frequently processes only 1–2 Tasks per successful batch and calls `Condition.wait` thousands of times. P18's at-most-one bounded additional search tends to recover inbox work and achieve full eight-Task batches. The native producer-success-cadence study (original archive SHA-256 `503c51d4b1220b9acf8c084d34dc746cbcfc4d3567c617b62886884ec5ff7f0e`) further showed, at one CPU/512 iterations/2048-slot ingress, M0 median real **Wait-entry** counts of **34, 5977, 4654.5** for producer success-phase Yield cadences 0/8/64, respectively, with **zero producer Full-retries** in *every* case. Those are repeated **calls to** `Condition.wait`, NOT measured kernel sleep durations.

That XPS archive reached sampled **100°C**, with **28/144 high-temperature processes** and **15 positive package-throttle counter deltas**. Consequently the cadence8/cadence64 one-core numerical speed estimates are **not thermal qualified**. Further ad hoc scheduler performance trials on the same conditions are not indicated.

The next necessary question is **correctness at the search-to-park linearization boundary**, independently of timing:
- What happens if publication arrives after a worker reads `wakeGeneration()` but before it checks `parkUnlessChanged(observed)`?
- What if a different worker drains the newly published inbox entry before the first worker reaches that guard?
- What if an owner publishes a stealable local-deque batch and calls `announceLocalWork()` after the first worker's unsuccessful steal scan?
- What if a worker is already inside the REAL `Condition.wait` when an inbox announcement or close occurs?
- Does the *same original implementation*, rather than a rewritten simulation, satisfy these checks under both M0 and one bounded P18 idle-search retry?

## Exact original code boundary and intended guarantee

The original M0 `source/concurrency/internal/submission_pool.d` has Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. Existing TaskInbox methods `trySubmit`, `wakeGeneration`, `announceLocalWork`, `close`, `completeOne` and `parkUnlessChanged` hold the same `Mutex`. The real prewait predicate is:

```d
while (_generation == observed &&
       _used == 0 &&
       !(_closed && _completed == _accepted))
{
    ++_parkCount;
    _changed.wait();
}
```

Note that `Condition.wait` *atomically releases* the associated mutex while sleeping and reacquires it before returning. The counter increments before the call; a count does not prove that Linux blocked for a positive duration. `_generation` is monotonically incremented on successful inbox acceptance, owner local-work announcement, close and last completion when already closed. Claiming a TaskRef from inbox does **not** decrement the accepted/completed execution obligation. The final completion wake is `notifyAll` only after close and accepted==completed.

P18's existing [source-pinned generator](../../../../tools/research/m1_p18_make_grace_pool.py) does **one bounded `Thread.yield()` retry** after an empty full search, recapturing a fresh ticket before the second search; it leaves TaskInbox mutex/Condition code and the final park predicate unchanged.

## Two different, deliberately bounded qualifications

**1. Native real-Condition source clones, no speed instrumentation.** The [exact-source fixture generator](../../../../tools/research/m1_p18_park_boundary_make_fixture.py) checks the M0 Git blob before producing uniquely named **research-only** M0 and P18 clones. It reuses the *existing P18 generator*; no public API, TaskRef storage, worker algorithm, producer cadence or production source edit is made. Each clone appends the same module-local test entry point with access to the existing **private** TaskInbox. DUB `park-boundary-control` and `park-boundary-grace` configs run the source-identical tests.

Cases exercised at inbox capacity 1 and 8, repeated eight times per binary (**96 direct checks**, excluding lower-level helper polling):
1. Success publication **after ticket capture, before park guard**: guard must not sleep.
2. Success publication followed by another worker's `takeBatch` **before guard**, leaving an empty inbox but still-outstanding execution obligation: stale ticket must not sleep.
3. `announceLocalWork` after ticket capture without any inbox contents: changed ticket must not sleep.
4. Close with no outstanding tasks after ticket capture: closed/drained guard must not sleep.
5. A live waiter actually reaches the `Condition.wait` boundary (verified by the real mutex-guarded `parkCount` and its release), then `announceLocalWork` wakes it; no missed notification.
6. A live waiter actually reaches `Condition.wait`, then close broadcasts and wakes it, and all obligations remain conserved.

Every native mode is checked in DMD 2.111 and LDC 1.41 debug and LDC whole-release via CI. Bounded rendezvous loops are guarded by an **external process timeout**, not a claim that all OS schedulers are fair. A deliberately altered M0 source file must cause **source-pin generator rejection before any generated output**.

These module-local TaskInbox tests are **not a replacement** for the existing native close-vs-producer, complete-vs-close, final outstanding obligation, and lifetime races, or for the multi-worker steal-cycle audit. They do not intentionally turn off generation checks in production.

**2. Independent abstract interleaving state model.** The [bounded Python reference model](../../../../tools/research/m1_p18_park_boundary_model.py) reads the exact M0 source blob and verifies the precise original generation guard text. It enumerates bounded interleavings of capture, unsuccessful search, optional P18 second capture/search, and atomic guard with up to three outside state transitions: accepted submit, foreign inbox claim, complete, local announcement, local claim and close. It asserts that the original predicate **never permits park entry with a stale generation, nonempty inbox or fully drained pool**. Deliberately disabling the **generation predicate in the model only** MUST yield a concrete counterexample (such as `announceLocalWork` after an empty search); this is a *negative-control* test of the model's discriminating ability.

**Limit:** The model assumes an indivisible locked guard, correct mutex and Condition implementation and source-level transitions as coded. It does not model D memory orders, every druntime wakeup, every thread placement/preemption, wraparound of `size_t` generations, non-terminating user Task callables, fairness, energy, or complete liveness. It is **not** a formal production proof. The native mode offers orthogonal real-D evidence for the selected scenarios, not exhaustive runtime-state coverage.

## Interpretation and further decision

A PASS supports **specific no-lost-publication and close/notify safety at the tested boundary**. It **does not explain** the observed thousands of Wait entries as a mutex bug; since P18 leaves this guard unchanged, the observed improvement is more consistent with avoiding/restructuring entry frequency, as supported by the prior batch/cadence evidence.

A failure must block any proposed scheduling or adaptive-idle policy change, and be triaged with original logs, source hash, and compiler versions **before further benchmarking**. Do not apply blind Yield/spin/power tuning. No new XPS run is required while CPU thermals are uncontrolled. If designing a new policy, qualify fairness, multi-producer/multi-worker, TaskRef/owned-task lifetime, close/race behavior, and uninstrumented native LDC 1/2/4-core performance separately when thermally stable.

**Disposition: KEEP P18 narrow research / DEFER unconditional production.** `source/`, `develop`, main, original M0, grandfathered R0.5 PR #35, ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT and all native evidence archives unchanged.


## Release-mode test-harness qualification note

The first exact-source native test introduced side-effect-bearing expressions inside D `assert(...)`, for example `assert(inbox.trySubmit(task) == SubmissionResult.accepted)`. In an optimized `-release` build assertions may be elided, including argument evaluation. The original test was therefore **not a valid release correctness probe**: it could omit the essential `trySubmit` and then block forever while using the real `Condition`. An observed 45-second LDC-release execution timeout in that *invalid test harness* does **NOT** demonstrate a lost production wakeup.

The repaired generator converts all **16** research-boundary assertion sites to an explicit `requireParkBoundary(bool, detail)` that always evaluates the condition/side effects and throws on failure in both debug and release builds. It rejects a changed assertion-site count. Build and run are split: the LDC release compiler is allowed to finish separately; only the resulting *prebuilt* native executable gets a 45-second completion deadline. DMD/LDC debugger and optimized execution must all report `P18_PARK_BOUNDARY_PASS scenarios=96` before making any claim that this boundary gate passes.

This does not alter original M0, P18's idle-grace code or any production test. It is an important **test-design regression** for future D whole-release research: do not put necessary state transitions exclusively into code subject to `assert` removal.
