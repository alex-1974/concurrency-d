# P42.20 — Initial correctness and record-return review

Date: 2026-10-22. Status: bounded local research qualification; promotion remains open.

## Reviewed baseline

- develop: `7af4409a2e09a303dfbc6c54033d28c92eb67581`.
- M1 research parent: `fcbe4f2a195942e71c73c20d2c6c6ed9b03385a7`.
- `submission_pool.d` SHA-256: `cdf437dde9046b64943c315f92892326fda45cf83ebfc19d71dd8ae4d0c6753e`.
- P42 generator SHA-256: `c405e9947877ca6021cfc461b95c908a55efcafa3a5f06eb072f8a79a8baa6d6`.

Production source is byte-identical to develop. P42.18/P42.19 used the historical two-argument generator (minimal waiter counter), not the later diagnostic worker/flow overlays. This review tests that exact minimal variant against the unchanged production baseline.

## Publication and progress argument

In the absence of native synchronization failures, publication, waiter enrollment and the park predicate share the inbox mutex. If a worker is enrolled when publication commits, conditional issues notify. If no worker is enrolled, skipping notify cannot lose a wake intended for an already enrolled worker. A worker whose ticket predates publication observes the changed generation before waiting; a later ticket precedes its new inbox/steal search. Publication still increments generation for every accepted task. A condition notification is not a stored work token.

This is a source-level lost-wakeup argument, with assumptions: mutex/condition contracts hold, generation does not wrap during a search, runnable workers receive CPU time, and callbacks eventually return. It does not prove bounded latency, fairness or starvation freedom. Woken workers may remain counted until mutex reacquisition; overcounting causes extra notifications, not intentional suppression of a counted waiter. The wait-exception path lacks guaranteed waiter decrement; native Condition failure remains outside the qualified normal path.

Local queue handoff still increments generation and calls notify. Close and final completion retain notifyAll. Batch size, complete foreign-victim scan, deque ownership, ingress FIFO/capacity and accepted/completed accounting are unchanged. Do not generalize publish suppression to those other notification sites.

## New native record-return witness

`consumer/p42_return_boundary.d` uses the real existing `afterExecution` hook, without altering scheduler source. One task executes; the callback signals entry and blocks before a final atomic record write. At that point accepted == completed == 1 but the final access has not occurred. Another thread calls closeAndJoin; the caller retains the GC record root and forces a collection, then releases the callback. After native join, the final write and exactly-once execution are checked.

Both arms exercise one and four workers. The witness that completion precedes the final record access is synchronized and deterministic. The 20-ms observation that join has not returned is only a bounded negative observation: a broken early-return implementation could evade this check if the closer were descheduled before calling join. The final post-join assertions and source review complement it; the test is not a proof for all schedules. The callback spin is test-only, externally time-bounded and is not a performance workload. Forced GC with an intentionally retained caller root is not a test of dropped-owner/root-registry recovery.

Run:

```sh
bash tools/research/m1_p42_return_boundary.sh dmd
bash tools/research/m1_p42_return_boundary.sh ldc2
```

Local results: DMD 2.111.0 debug PASS (both arms); LDC 1.42.0 debug and -O3 assertions-on PASS (both arms). CI is configured to run this gate with its existing pinned DMD 2.111.0/LDC 1.41.0 matrix, but has not run the new change. Local LDC 1.42.0 evidence must not be labelled LDC 1.41.0 evidence.

## Lifetime and failure disposition

The pool transports non-owning TaskRefs. It neither validates arbitrary capture graphs nor makes an arbitrary delegate safe. `completeOne` precedes `afterExecution`; completed counters and result-ready flags are not storage-reclamation barriers. Successful native worker join remains the pool's caller-storage boundary; the owned layer uses a separate release/acquire returned marker for earlier reclamation.

Existing M0 failure limitations remain: startup accounts a worker after Thread.start returns; sequential joins can stop on an exception; OwnedTaskExecutor stores a shutdown error but still moves to stopped after failed join. Its retained roots are not cleared in that failure branch, which helps retention but does not establish native quiescence or safe caller-stack unwind. P23–P29 investigate different source-pinned ownership/supervision protocols. Conditional does not solve these problems and must not be advertised as doing so.

## Next qualification slices

1. Transfer the deterministic ticket/search/park and local-handoff fixtures to the minimal conditional overlay, with explicit barriers, negative controls and bounded watchdogs; existing observed-overlay smoke/stress and finite models remain supporting evidence.
2. Run the actual owned task layer with the conditional pool under source-pinned import substitution: typed results, caught task failures, dropped handles, captured GC graphs, returned-marker reclamation and concurrent close/admission. Preserve existing native-failure exclusions and add no broad trusted wrapper.
3. Qualify an independent CPU-heavy consumer and event-loop completion handoff, including idle/burst tails. Then make a narrow scheduler promotion decision separately from unresolved general TaskScope/public ownership design. No need to repeat the full P42.19 throughput experiment unless code/workload changes invalidate that evidence.

Disposition: KEEP conditional as a performance candidate. This is an initial P42.20 slice, not completed production qualification. ADR remains Proposed; PR #38 remains Draft; no merge or production-source change.

## Additional local regression receipt

Existing m1_p42_conditional_gate.sh PASS on DMD 2.111.0 and LDC 1.42.0. The adversarial, local-handoff, ticket-enrollment and two-worker Python models PASS with expected negative controls. Root dub test PASS on each compiler (five unittest modules). These bounded checks do not upgrade model assumptions into runtime guarantees. Shell syntax and diff whitespace checks pass.

## Implemented follow-up: controlled races and actual owned consumer

The initial next-slice list above is retained as the progression of this review. The first two slices and a small CPU/completion-handoff consumer are now implemented in `tools/research/m1_p42_20_qualification.py` and this directory's `consumer/` sources.

The runner verifies SHA-256 pins for the actual M0 pool, actual owned executor and historical P42 generator, then builds isolated temporary DUB packages. Production sources are never overwritten. The owned module differs only in its module declaration and pool import. Its pool uses the minimal measured conditional overlay without race barriers. The baseline uses the same waiter accounting with unconditional publish notification; it is a matched policy control, not byte-for-byte original production source. Earlier root-unit and return-boundary tests additionally cover the original production module.

A separate generated barrier pool tests:

- publication before ticket capture, after ticket capture, and after a completed empty search before park;
- close at each of those three barriers;
- publication after observing an enrolled waiter under the inbox mutex;
- two tasks prefilled BEFORE worker launch, forcing a batch claim. The claimant pauses before local enqueue while the peer enrolls in wait. After release, the claimant publishes local work and blocks in its first task; the peer must execute the second task before owner release or close.

No close broadcast may rescue successful publication/handoff checks before the required execution observation. Two deliberately invalid policies must be detected: suppressing publish notify with a confirmed waiter, and suppressing local notify while the owner blocks. Detection occurs before rescue; all records are subsequently drained and joined. The isolated binaries return distinct expected exit codes 23/24 and required witness markers, avoiding confusion with DUB's exit-code wrapping. Watchdogs bound subprocess duration. Negative observation windows are finite (1.5 seconds) and OS spurious wakes could prevent a mutant from being observed; neither this nor a positive finite run proves universal liveness.

Actual owned qualification covers typed and void success; Exception recording and rethrow; result/error cell survival after record reaping and GC; repeated shutdown; twelve four-producer rounds with two external close callers; per-record admission/execution conservation and zero retained nodes after successful join. Those rounds are bounded concurrency stress, not deterministic enumeration of all admission/close schedules. A seeded task guarantees nonempty accepted work. The original P19 graph consumer is also run with only its owned-module import changed: eight queued jobs with three-node GC graphs, dropped handles, four forced collections while blocked, and result access after reaping. An explicitly @safe submission fixture must still fail with the intended @safe/@system submit diagnostics.

The independent CPU consumer submits 48 value-only chunks and polls typed completion cells. Workers return checksums; only the controlling thread applies completed results to its aggregate. Worker identity and controller affinity, per-chunk results, full checksum, completion counts and root clearance are checked. This is a small event-loop-style handoff simulation, not integration with a GUI framework or a latency benchmark. Submission remains @system.

### Final local receipt

| Compiler/build | Baseline/conditional races | Real owned + P19 GC graph | CPU handoff | Invalid-policy controls |
|---|---|---|---|---|
| DMD 2.111.0 debug | PASS/PASS | PASS/PASS | PASS/PASS | both detected |
| LDC 1.42.0 debug | PASS/PASS | PASS/PASS | PASS/PASS | both detected |
| LDC 1.42.0 -O3, assertions enabled | PASS/PASS | PASS/PASS | PASS/PASS | controls run in debug |

Reproduce with `python3 tools/research/m1_p42_20_qualification.py dmd` and the corresponding `ldc2` invocation. CI now includes the runner and both push/PR path filters. Its pinned LDC 1.41.0 qualification remains pending publication and an actual CI run.

### Decision after implementation

The new bounded normal-path checks support continuing toward a narrow conditional publish-policy adoption. They do not authorize a general TaskScope or recoverable native lifecycle guarantee. No production source, release API, original benchmark evidence or ADR status changed. Remaining work: pinned CI; review of the generated synchronization delta and test assumptions; genuine idle/burst latency-tail evidence if those claims form part of acceptance; then an explicit selective scheduler promotion decision. Native start/join ambiguity and arbitrary borrowed captures remain separate unresolved ownership boundaries.
