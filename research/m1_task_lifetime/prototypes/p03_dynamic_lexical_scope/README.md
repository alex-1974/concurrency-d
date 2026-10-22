# M1 P03 — Bounded dynamic lexical task scope

**Status: PASS for the explicitly tested P03 research kernel only. NOT an accepted `TaskScope` API.**
**Issue:** [#17 — scoped borrows and ownership](https://github.com/alex-1974/concurrency-d/issues/17).
**Related:** [ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [P01](../p01_scoped_join/README.md), [P02](../p02_lexical_batch/README.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Question answered

Can the qualified non-owning 8-byte `TaskRef` support **dynamically published work inside a lexical call** while the records remain address-stable and **every accepted child reaches post-dispatch quiescence before the call returns**?

**P03 answer for a bounded single-producer research configuration: YES.** The prototype demonstrates a serial producer interleaving publication with completion while two workers execute tasks. A `finally` inside the lexical runner closes and joins both workers, regardless of whether the producer callback returns normally or throws an ordinary `Exception`. This is **not** a claim of general `@safe` borrowed capture semantics, concurrent producer close safety, or arbitrary nested structured execution.

## Mechanism and constraints

- Research code only in `concurrency/research/m1_dynamic_scope.d`; production `concurrency.internal.task_record` is compiled directly **without modification**. A `TaskRef` remains a non-owning, one-word pointer to a header-first task.
- Lexical entrypoint: `private Outcome runScoped(scope Build build) @system`. The only producer is the caller's builder; it receives a private `Portal*` capability. `Portal` and its `PinnedRecord[24]` remain in the entrypoint's stack frame.
- `Portal.trySpawn(Work)` publishes **at most 24 distinct records total**. An accepted slot is never reused, even if that child has already returned. `@disable this(this)` blocks ordinary copies of records and the portal. It does not prevent unsafe bytewise relocations by arbitrary `@system` consumers.
- `Engine` uses a bounded **eight-slot** condition-variable FIFO and two native worker threads. Submission checks queue fullness under the same mutex used for publication/worker claims; full-inbox rejection does not create an accepted task. Closed/oversized storage also rejects before publication. No blocking submission when the inbox is full.
- Worker `dispatchTask(task)` executes the callback via the existing qualified thunk, stores a release `returned` marker **after dispatch**, then increments the returned count and wakes an external controller waiting for completion. `waitUntilReturned` is **external-producer-only**; calling it inside worker tasks of a saturated pool can deadlock and is explicitly not supported.
- An ordinary callback `Exception` is recorded by its pinned record and counted **only after all workers join**; sibling tasks still run. Cancellation is intentionally **not** present in this P03 API: it cannot be inferred from having a join barrier.
- `scope Build` constrains escape of the builder's delegate parameter itself in some `@safe` contexts. It **does not enforce transitive safety of every delegate captured and submitted to worker threads**. Consequently `runScoped`, `Portal.trySpawn` and the builder are `@system`. A source-level `static assert(!__traits(compiles, ...))` verifies that a purported `@safe` caller cannot directly invoke `Portal.trySpawn` under the qualified compilers; that is an **attribute check only**, not a scope borrow checker.
- The P03 thread engine and mutexes are GC allocated, so this experiment does **not** measure a zero-allocation scheduler. The records themselves are lexical, pinned and non-owning; GCs must still retain the closures/objects they reference while tasks are in flight.
- The narrow `@trusted` cast from `shared(TaskHeader)*` back to pinned `PinnedRecord*` is a P01/P02-style implementation boundary. The test synchronization helper has separate `@trusted` methods for druntime `Condition` methods, and the GC stress helper wraps `GC.collect`. None certifies arbitrary user callback data-race freedom.

## Executed scenarios

| Test | Observed invariant |
|---|---|
| Backpressure with blocked workers | Two executing gate blockers plus eight queued accepted tasks; the next admission fails while the queue is full; after release all **ten** accepted records are joined. |
| Dynamic admission after completion | Three rounds of eight jobs; producer explicitly waits for each eight to return before submitting the next eight. The total **24 unique pinned records** complete. |
| No slot reuse in scope | A 25th submission fails even after queue drains, preventing overwriting a previously published record's storage. |
| Producer exception/unwind | Builder throws after two accepted jobs; the lexical `finally` waits for both to finish before the error is rethrown to the outer test. |
| Child exception isolation | One child throws an ordinary `Exception`, sibling work still finishes; outcome counts one recorded child error after join. |
| GC-visible captured referent | Task captures a GC class, calls a test-only forced collection, and reads its member before post-dispatch completion. This is a focused liveness control, **not** comprehensive concurrent GC-stress qualification. |
| Destruction ordering | A noncopyable local guard asserts its borrowed work has returned before destruction; the destructor runs once after exiting the lexical block. |
| Attribute boundary | Ordinary record copy rejected; `@safe` function cannot invoke `Portal.trySpawn` (checked with `__traits(compiles)`); `@system` remains explicit. |

## Exact evidence

**Implementation and runner at commit `0bf6c574e6691232dbc725ea0c4cf8e120e1c206`.**
[GitHub Actions run #38377974746](https://github.com/alex-1974/concurrency-d/actions/runs/38377974746): **both jobs PASS**.

- DMD 2.111.0 job **115231028533**: P03 compile and runtime PASS, plus inherited P01/P02 and **4 positive / 5 negative** DIP1000 frontend fixtures PASS.
- LDC 1.41.0 job **115231028946**: same P03 PASS under normal and optimized **`-O3` with assertions enabled**; inherited probes PASS.
- First P03 attempt [run #38377738583](https://github.com/alex-1974/concurrency-d/actions/runs/38377738583) failed compilation because the identifier `out` is a D keyword. Kept as original diagnostic evidence; changed to `result` before passing [#38377806744](https://github.com/alex-1974/concurrency-d/actions/runs/38377806744) and adding the explicit `@safe` submission rejection at the final source SHA.

To reproduce locally, from repository root:

```sh
bash tools/research/m1_dynamic_scope_prototype.sh dmd
bash tools/research/m1_dynamic_scope_prototype.sh ldc2
```

The runner compiles the repository's actual M0 task-ref module, not a duplicate mock, and enables `-preview=dip1000`. Both compilers additionally execute `-release`; LDC also executes `-O3` without `-release`. Essential admissions and runtime correctness conditions now use always-evaluated `ensure` rather than removable `assert`.

## 2026-10-15 release-mode harness qualification

The original P03 research harness used `assert(portal.trySpawn(...))`
for **essential task admission** and ordinary `assert` for nearly all
post-join oracles. Under `-release`, D removes those calls, so the original
fixture was **not a valid whole-release correctness test**: it could omit
published tasks, stall on the test-only blocked-worker rendezvous and skip
outcome verification. This is a **test-harness bug**, not evidence of a defect
in the M0 scheduler or a newly discovered compiler error.

The research-only P03 source now uses an always-evaluated `ensure(bool)`
helper for admission and all runtime checks. Its three static
`static assert` compile barriers remain unchanged. The blocked-worker
backpressure scenario releases its test semaphore in `finally` even if a
requirement throws before normal release; destructor ordering writes a
nonthrowing atomic violation flag, checked **after** destruction, rather than
throwing from a destructor. The P03 native runner now **compiles and executes**
normal, `-release` and (for LDC) `-O3` correctness configurations, under
bounded subprocess timeouts. The real original `TaskRef` transport remains
unchanged. No public API, new ownership guarantee or scheduling policy is
implied.

**Exact research-only code gate:** [CI #38712094608](https://github.com/alex-1974/concurrency-d/actions/runs/38712094608)
at commit `d928726418e2d16f0f6ea450818a46b3cda05131`:
DMD 2.111.0 / LDC 1.41.0 P03 Debug and `-release` stages passed;
LDC additionally ran `-O3` with assertions enabled. The long-running full
P01–P18 workflow should be checked separately before declaring the entire
branch green. The after-the-fact runner timeout/documentation change itself
also needs its own exact-head CI gate.

**Boundary unchanged:** `runScoped` and task submission remain `@system`;
short-lived nested block borrows are not compiler-proved, arbitrary callback
data races are not addressed, and native `Thread.start`/join failure does
not have a proved recoverable lifetime semantics. Retain ADR-0001 **PROPOSED**,
Issue #17 **OPEN**, PR #38 **Draft**, and `source/` unchanged.

## Nested-block ordering witness (2026-10-15; new evidence gate)

The new `testNestedBlockOrdering` exercises the **actual P03 engine**
with one admitted task. A worker enters a test gate while a nested lexical
`InnerGuard` is still alive. The builder then leaves that inner block;
the guard's destructor stores a release atomic marker. **Before the
outer `runScoped` builder returns or its final join starts**, it observes
that the nested block has ended. Only then does the builder release the
worker, which sees the acquired marker and completes. The outer join still
properly accounts for the admitted TaskRef.

This is a **bounded scheduling/lifetime-order witness**, not an attempt to
access a destroyed object. The worker reads only atomics whose referents
outlive the joined task; **no expired pointer is passed or dereferenced**.
Its purpose is to invalidate the inference that an *outer* scope join alone
also keeps all *inner* lexical-block resources alive. It does not establish
the compiler's treatment of particular captured raw-pointer/delegate forms,
nor does it prove a data race or memory-safety violation.

The source uses always-evaluated `ensure` checks, a `finally` gate
release and a nonthrowing destructor. The native runner requires the exact
`P03_NESTED_SCOPE_ORDER_PASS` marker, not merely process exit status, in
normal, `-release` and LDC `-O3` test modes. A missing marker or timeout
fails the gate. The checker is research-only. **Do not interpret its PASS
as justification for changing P03's `@system` annotation.**

**Executed qualification:** [CI #38713663752](https://github.com/alex-1974/concurrency-d/actions/runs/38713663752) completed successfully at commit `1cd40c66b18489fa1ae1b4d196cd9f0b66a5b76a`. Both DMD 2.111.0 and LDC 1.41.0 passed the nested-block ordering marker in normal and release execution; LDC also passed optimized `-O3`. The P01–P18 workflow completed successfully. This supports only the bounded ordering observation, not a new public `@safe` lifetime guarantee.

## Design limits / GO-NO-GO

**KEEP (research):** lexical dynamic TaskRef publication with one producer, bounded pinned task records, fixed worker count, exception-safe join and no detach. This demonstrably extends P02's one-shot batch capability without changing the one-word transport.

**NOT ACCEPTED / NO-GO as public `@safe` TaskScope:** `@system` submission can capture a pointer to a **shorter-lived block inside the builder** and publish it to an asynchronously running worker. An outer `finally` join does not repair referents destroyed **before builder return**; mere `scope` annotation on the builder cannot prove per-child borrowed lifetime. Similarly, `@safe` callback bodies do not imply race-free access to arbitrary captured mutable state. An actual safe API must address those hazards without globally trusting user callback graphs.

**OPEN:** dynamic worker-side nested spawn and worker-side join (deadlock hazards), concurrent producer/close linearization with meaningful capture ownership, cancellation propagation and child-error policy, valid local borrowed referent lifetimes **at every submission point**, GC root stress and destructor exactness across move-only closures, terminal `Error` semantics, typed results, runtime performance and realistic consumer qualification.

**Next research recommendation:** do not label this `TaskScope` implementation accepted. Evaluate one of two honest API envelopes: (a) a synchronous lexical batch with `@system` captured delegates (currently P02/P03), or (b) a scope-controlled typed operation with compile-negative **consumer** tests that establish a constrained `@safe` closure/capture boundary. Model nestable scopes separately from concurrent-producer ownership. Retain this evidence on the grandfathered research branch; do not merge the whole research line into `develop`.

No production files, default branch or the unrelated R0.5 research branch were modified.
