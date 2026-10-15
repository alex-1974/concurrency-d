# M1 P11 — CT-specialized inline tasks on the actual M0 work-stealing pool

**Research date:** 2026-10-13  
**Status:** scoped P11 **PASS** for DMD 2.111.0, LDC 1.41.0 and the opt-in LDC -O3 asserts-on configuration. **NO-GO** for public general `@safe` executor, production lifetime certification or performance claims.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Parents:** [P09 conservative inline transfer](../p09_transfer_contract/README.md), [P10 typed TaskRef and isolated FIFO](../p10_typed_transport/README.md), [P07 native worker error boundary](../p07_native_lifecycle/README.md).

## Research objective and exact integration

P10 demonstrated a typed header-first record carrying a P09-approved inline payload/result over the **real TaskRef/dispatchTask transport**, but supplied its own small FIFO and created two native threads for every batch.

P11 replaces that isolated scheduler with the **actual unchanged** M0 worker pool and actual `containers-d 0.2.0` work-stealing deques:

- Real `source/concurrency/internal/task_record.d` — one-word TaskRef with a typed header-first execute thunk.
- Real `source/concurrency/internal/submission_pool.d` — SubmissionWorkerPool, TaskInbox, owner-local deque, cross-worker `steal()`, epoch/condition-variable parking, admission and completion hooks.
- Real `source/concurrency/internal/work_stealing_queue.d` — alias to the container library's WorkStealingDeque.
- Real `source/concurrency/internal/owned_task.d` — independent owned-node/task-handle consumer of the *same* SubmissionWorkerPool for correctness parity.
- Conservative P09 `isInlineTransfer!P`/`!R` imported from the actual prior research module.

The opt-in [research-only DUB package](dub.sdl) declares a **path dependency on the unchanged root concurrency-d package**, resolving its real `containers-d 0.2.0` dependency. Its own `dflags "-preview=dip1000"` applies **only to this private research app**, not to published concurrency-d consumer flags. DUB 1.40.0's CLI does **not** support the initially attempted `--dflags` option; that invocation failure was corrected without altering the production manifest. The P09 trait source file is listed explicitly to prevent DUB from compiling P09's separate standalone `main()`.

## Typed work and actual M0 scheduling

[Research module: m1_real_pool.d](concurrency/research/m1_real_pool.d)

```d
PoolResults!R evaluateWithRealPool(P, R)(
    scope P[] input,
    R function(P) @safe pure nothrow @nogc operation,
    size_t workerCount = 2,
    size_t ingressCapacity = 4) @system
    if (isInlineTransfer!P && isInlineTransfer!R);
```

- `TypedRecord!(P,R)` holds a header-first CompletionPrefix, typed noncapturing function pointer, copied P and result R; the execute thunk is specialized at compile time. `@disable this(this)` blocks ordinary copies of a record once published.
- The producer creates and initializes a **fixed-address 256-record array**, then publishes their non-owning TaskRef headers into the real pool. This is a bounded **synchronous**, research-only family, not independently retained/asynchronous owned tasks.
- Real M0 admission returns `accepted/full/closed`. On `full`, the producer increments a diagnostic retry counter and yields; it does not silently allocate an unbounded submission backlog.
- After real pool shutdown, verify accepted and completed counts exactly match submitted tasks. The real `afterExecution` callback additionally marks each record `returned=1` with release atomics after dispatch/completion accounting, and the caller reads flags with acquire atomics **after successful native worker join**.
- Results are copied into inline `PoolResults!R.values` only after all worker joins returned successfully. A ready output is **not** treated as quiescence independently of join.
- Research failure policy deliberately catches `Throwable` around the **pool join** and calls `abort()` rather than unwinding possibly live stack TaskRefs. This is not an acceptable public availability contract or proof that all druntime/native errors have been handled. The actual M0 pool's constructor may throw after native launch, although **no P11 TaskRef has been published yet** at that point.
- Crucially, `evaluateWithRealPool` is marked **`@system`**, never `@trusted` or `@safe`: existing M0 lifecycle and native join failure handling remain unqualified, even when P/R are plain data and the operation pointer itself is `@safe`.

The helper does not add a virtual base class or per-task TaskHandle/ResultCell/OwnedNode. The fixed records are stack-resident. This **does not** mean the complete execution is allocation-free: the real pool constructs threads, ingress queues, deques, conditions and mutexes; and it does not mean the two implementation families have identical semantics.

## Real positive consumer and result parity

[Research DUB consumer](consumer/main.d) executes:

1. 256 copied integer values on **one, two and four native workers**, ingress capacity four, checking values, exact accepted/completed and all 256 post-dispatch returned flags;
2. 16 repeated 16-task scopes over four workers with deliberately smaller ingress (capacity two);
3. `Point2` POD to distinct `Cell` POD results, including negative inputs;
4. structs containing nested fixed arrays to `long` results, plus independence of prior result from later source mutation;
5. empty input, oversized >256, null function pointer and zero-worker rejection;
6. a separate **actual OwnedTaskExecutor** with the same 256 source integers, the same `calculate` kernel, four workers and ingress four: independently awaits TaskHandle results and checks byte-identical integer output to the typed P11 pool, then joins the real owned pool.

**Fairness limit:** OwnedTaskExecutor retains per-task nodes/results/handles and offers asynchronous independently awaited results, while P11 owns caller-stack records and returns a synchronous inline result array. Both exercise the **same real M0 worker pool and operation**, but the ownership/result-availability and allocation semantics differ; **correctness parity is not a fair latency/throughput comparison**.

## Deterministic proof that real cross-worker stealing executes

[Steal probe source](concurrency/research/m1_steal_probe.d) is a **separate @system task-record experiment** using the same unchanged M0 pool. It is deliberately not part of the `@safe` typed-P/R consumer and uses atomic gate flags.

The test orchestrates this schedule:

1. The two native workers enter separate preparatory tasks **PrepA** and **PrepB**, both blocked on atomic release flags. Verify both entered.
2. While both workers remain occupied, the producer submits one **Head** task and seven **Remaining** tasks to the ingress queue. Its capacity is 16, so all eight remain queued; neither worker can take them yet.
3. Release *only* PrepA. Its worker returns to the M0 loop, drains the entire eight-task inbox batch, pushes seven entries into its own local work-stealing deque, then executes **Head**, which blocks and signals entry.
4. PrepB's worker remains blocked throughout step 3. Once **Head** has entered, release *only* PrepB. Its worker finds the global ingress empty; the seven remaining tasks are on the other worker's local deque. It can execute them only through the **real M0 cross-worker steal branch**.
5. Wait until exactly **seven** Remaining tasks finish while the owner worker is **still blocked in Head**, then release Head, join both workers and check accepted=completed=10.

This does not infer steals merely because the pool is *capable* of stealing: the controlled schedule demonstrates the seven tasks execute while their owner is blocked and the ingress is empty. No production instrumentation, fake deque, or substituted scheduler is involved. It proves the branch for this controlled Linux/DMD/LDC schedule, **not** an arbitrary workload distribution, overall fairness or starvation freedom.

## External compile-negative API gates

The DUB research manifest has separate consumer configurations; each compiles through the exact same root concurrency-d/containers-d dependency graph as the positive consumer:

| Configuration | Actual rejected call | Both compilers' intended error |
|---|---|---|
| `negative-safe` | `@safe` function attempts P11 `evaluateWithRealPool` | cannot call `@system` pool frontend |
| `negative-borrow` | P contains raw pointer field | constrained `isInlineTransfer` overload unavailable |
| `negative-delegate` | D captured-context delegate instead of a function pointer | no matching `evaluateWithRealPool` overload |

The runner requires a **compile-stage error at the actual P11 overload**, not an arbitrary DUB/build/link failure. Both pinned compiler logs were checked manually as well.

## Qualification and exact evidence

**P11 code + runner source commit for the normal and negative checks:** `2be4023bb8b3eec1a9cbbfe79083b19f8a72cde0`. [GitHub Actions #38405054192](https://github.com/alex-1974/concurrency-d/actions/runs/38405054192) **PASS** both matrix jobs, including the deterministic seven-steal proof.

**Optimized-correctness follow-up:** research manifest adds an opt-in **`optimized` DUB configuration with `dflags "-O3"`**, invoked as a **debug build** to retain assertions. [GitHub Actions #38405288768](https://github.com/alex-1974/concurrency-d/actions/runs/38405288768): **DMD 2.111.0 and LDC 1.41.0 PASS**; LDC's optimized configuration reruns the real-pool consumer (including seven-steal proof, owned parity and all asserts) and prints `P11 LDC -O3 research configuration (assertions-on): PASS`.

Preceding failures retained in workflow history:
- [#38403586139](https://github.com/alex-1974/concurrency-d/actions/runs/38403586139): DUB 1.40.0 rejects proposed CLI flag `--dflags`.
- [#38403752583](https://github.com/alex-1974/concurrency-d/actions/runs/38403752583): D syntax rejected `catch` inside `finally`; a named POD callable needed explicit field initialization.
- [#38404072271](https://github.com/alex-1974/concurrency-d/actions/runs/38404072271): DUB initially included P09's standalone supervisor `main()`, causing a duplicate entry point; the research manifest now includes only the P09 trait source.

These are **P11 research/runner defects, not a claim of bugs in the pinned toolchains, containers-d or the M0 scheduler**.

Reproduce from the repository root (requires DUB and the pinned toolchain; DUB resolves containers-d 0.2.0):

```sh
bash tools/research/m1_real_pool_prototype.sh dmd
bash tools/research/m1_real_pool_prototype.sh ldc2
```

The script runs the positive DUB app, three separate expected-rejection DUB configurations, and additionally the optimized research config for LDC. P01–P10 research gates and existing DIP1000 language-negative checks continue to run in the same workflow.

## Structural and performance assessment (NO timings)

| Property | P10 own bounded FIFO | P11 actual M0 typed caller-stack records | Actual M0 OwnedTaskExecutor |
|---|---|---|---|
| Typed P/R payload | Yes | Yes | Arbitrary generic callable F/R |
| TaskRef and specialized thunk | Actual M0 | **Actual M0** | Actual M0 |
| Scheduler | Research mutex FIFO | **Real M0 ingress + work stealing + parking** | **Same M0 pool** |
| Worker lifetime | New workers per call | New real pool per call | Long-running across multiple submissions |
| Result | Synchronous R inline array | Synchronous R inline array | Independently awaited TaskHandle/ResultCell |
| Task record | Fixed private stack array | Fixed private stack array | GC-owned retained class nodes |
| Capture ownership | Context-free pointer/inline P/R | Context-free pointer/inline P/R | Arbitrary F at `@system` boundary |
| Native failure policy | Research fail-stop | Research fail-stop only around pool close | M0 shutdown risks from P06–P09 still apply |
| Evidence | P10 compiler/runtime qualification | **Correctness, real-steal, owned-result parity** | Same numerical operation validated |
| Proven performance benefit | **None** | **None** | **None** |

P11 does not record throughput/latency distributions, allocation profiles or normalized dispatch costs; the requested ambitious performance goal remains **OPEN**. The architectural comparison is meaningful, but presenting a measured speed win would be false because the owned and lexical families differ in worker lifetime, allocation, task completion and result contracts.

An appropriate next research slice would run a **shared long-lived M0 worker pool** with matching closure/ownership obligations for both paths and isolate task admission/dispatch costs, or explicitly benchmark only the per-record header-thunk microkernel with its narrower semantics. Include native optimized LDC codegen, OS/CPU pinning and repeated sample distributions before drawing a C++ parity or high-performance conclusion.

## Release-mode ownership/result oracle hardening — 2026-10-15

The P11 real-M0 copied-input consumer and the separate independently owned
`OwnedTaskExecutor` consumer already test the two distinct lifetime families
with identical scalar results. An audit identified a release-only harness
defect: `assert(handles[i].get() == typed.values[i])` **elides the entire
handle-result observation** under D `-release`. Other result/count/steal
oracles were also `assert`-based, and a steal-phase time limit relied on
assertions enabled by debug builds.

Research-only changes make the consumer checks **always executed**, including
all 256 `TaskHandle.get()` observations. The real-steal gate always checks
admissions, worker rendezvous deadlines, task results and post-join counters;
an invalid test record kind now unconditionally fails the test process.
The typed P11 pool checks accepted/completed/returned invariants even with
D assertions removed. The P11 runner executes an additional **full DUB
release** `positive` consumer with a required final marker, for **both
DMD and LDC**, alongside the existing debug, compile-negative and optimized
assertions-on research tests. A timeout bounds every native process.

The new gate is correctness-only. No semantic change to `TaskRef`, M0
`SubmissionWorkerPool`, GC-owned task nodes or producer admission; no
cross-family throughput claim. P11 remains deliberately `@system`, and
its native failure/borrowed lifetime promises are **not upgraded**.
**Executed and qualified:** [GitHub Actions #38714944406](https://github.com/alex-1974/concurrency-d/actions/runs/38714944406) is **SUCCESS** at exact code commit `ae0a6a23b617b162a8a4eb6ee15b737ad2ead4a3`. Both pinned `DIP1000 / dmd-2.111.0` and `DIP1000 / ldc-1.41.0` jobs built and **actually ran** P11 in debug and full DUB release. LDC additionally ran optimized debug `-O3`. All separate P11 compile-negative consumers and remaining P01–P18 research gates passed. The first CI attempt encountered a research-only `requireSteal(bool)` signature mismatch with a pre-existing diagnostic argument; it was corrected to preserve that argument before qualification. No production scheduler failure was identified.

## P19 complement — owned task graph retention

[P19's real-M0 owned GC-graph experiment](../p19_real_owned_gc/README.md)
extends this P11 result-parity research with one blocked worker,
eight queued nested three-class GC payload graphs, abandoned submission
handles, four forced GC collections, exactly-once execution, and
independent result-cell observation after post-dispatch record reaping.
The test's explicit, always-evaluated oracles execute in whole release,
and its external `@safe` generic-owned submission is compile-rejected.
This is a **bounded ordinary lifecycle test**, not a compiler-verified
transitive ownership rule or native-failure recovery.

## Safety verdict

**KEEP P11** as a reproducible, compiler-qualified integration of P09/P10 typed records with the *real* M0 scheduler and concrete steal path. The P11 API is intentionally `@system` and supported by three negative consumers; no public-facing type/API is frozen.

**NO-GO** for a general parallel `@safe` TaskScope or owned executor promotion. Positive execution, seven real steals and worker joins on a normal run do **not** prove safety under fatal callback Error, failing native join, native start-after-launch error, GC executor abandonment, or arbitrary captures. The current M0 pool still uses default throwing joins and has no accepted complete post-native-start/fail-closed lifecycle contract; P07 research fail-stop is not a production-approved availability policy. No productivity/performance comparison is promoted.

Keep [ADR-0001](../../../../docs/adr/ADR-0001-task-lifetime-families.md) **PROPOSED**, Issue #17 **OPEN**, PR #38 **DRAFT**. Leave `source/`, production `dub.sdl`, `develop`, and grandfathered R0.5 PR #35 unchanged.
