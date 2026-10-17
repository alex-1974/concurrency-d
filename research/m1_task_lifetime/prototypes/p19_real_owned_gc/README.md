# M1 P19 — Real M0 owned GC graph retention and result lifetime

**Status:** Bounded real-executor correctness research; not a production API
or a general `@safe` ownership proof.  
**Tracking:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17),
[ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md),
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).  
**Prerequisites:** [P08 failure/retention model](../p08_owned_vs_borrowed/README.md),
[P09 data-only transfer](../p09_transfer_contract/README.md),
[P11 actual M0 scheduler / owned parity](../p11_real_pool/README.md).

## Question

Does the **actual** `source/concurrency/internal/owned_task.d`
`OwnedTaskExecutor` retain a normally accepted task record and its nested
GC-managed callable referents while **all submitting handles and the task's
local submit frame have gone away**, and does a separately owned result
handle still work after its **record** has become post-dispatch
reclaimable and been reaped?

P08 and P09 previously tested the failure model and conservative data
transfer. P11 tested actual typed work-stealing parity and release result
observation, but did not isolate a **queued, unexecuted callable containing
a nested GC graph after dropping handles**. P19 adds that bounded ordinary
runtime control rather than duplicating the scheduler or inventing another
task API.

## Unchanged implementation and test boundary

[Actual D consumer](../p11_real_pool/consumer/p19_owned_graph.d) compiles
through the [P11 DUB research manifest](../p11_real_pool/dub.sdl) with its
real root `concurrency-d` package and pinned `containers-d 0.2.0`.
It uses the unmodified production `OwnedTaskExecutor`,
`SubmissionWorkerPool`, one-word `TaskRef`, work-stealing deques,
`TaskHandle` and `ResultCell`. No new public API, queue implementation,
native thread lifecycle or task allocator is introduced.

### Control A: pending GC-reference graph

- One executor, one worker, queue capacity eight and bounded retained-node
  capacity nine. An accepted `void` task enters a semaphore and blocks.
- A **different helper frame** submits eight distinct typed
  `GraphTask` struct callables. Each holds a chain of three GC classes and
  a separate GC-managed receipt. Each accepted `TaskHandle!int` is dropped
  before the helper returns. The initial blocker handle is also dropped.
- Before releasing the worker, require **accepted=9**, **completed=0**,
  **retained=9**, and `reclaimCompleted()==9`. The eight tasks are
  not executable while that single worker is blocked; no task is licensed
  for reclamation.
- Force **four** `GC.collect()` calls and reconfirm the retention and
  completion counts while the queued tasks remain unexecuted.
- Release the blocker in `finally`, perform real
  `closeAndJoin()` with a research-only fail-stop if its native lifecycle
  fails, and require accepted=completed=9, retained=0. All eight receipts
  must show exactly one execution and the expected checksum over **all
  three** levels of each graph.
- Admission, receipt and accounting checks use an always-evaluated
  `require()`, not `assert()` with side effects. This is also compiled
  and run as a **whole DUB release** executable.

The receipt remains independently reachable by the test controller; the
nested graph referents are owned by the accepted callable, not the
receipt. D's conservative GC may retain objects through compiler or stack
roots not explicitly modeled by this experiment; collection-plus-success
does **not** constitute a proof of exclusive root reachability or
transitive memory safety for all callable types.

### Control B: result handle after reaping

A scalar owned task completes and its `TaskHandle!int` is read. The
controller then waits for `reclaimCompleted()==0` (the distinct
post-dispatch-return marker), checks `retainedCount()==0`, forces
a GC, and reads **the same independent result handle again**. A ready
result is not confused with the last worker access.

### Compiler-visible boundary

The separate [negative-safe fixture](../p11_real_pool/consumer/p19_negative_safe.d)
tries to submit an owned callable from an explicitly `@safe` consumer.
DMD/LDC must **reject the actual `OwnedTaskExecutor.submit` call** as
`@system`, not merely produce a missing module or link error. An arbitrary
struct copied into GC-owned storage may still contain a borrowed pointer;
P19 does not relabel this generic family as intrinsically safe.

## Reproduction

From repository root:

```sh
bash tools/research/m1_owned_gc_real_pool.sh dmd
bash tools/research/m1_owned_gc_real_pool.sh ldc2
```

[Runner](../../../../tools/research/m1_owned_gc_real_pool.sh) requires an
exact runtime PASS marker in **debug and full DUB release** on both
compilers; LDC also executes debug `-O3` correctness. Separate
compile-negative consumer rejects a `@safe` generic owned submission.
Each spawned DUB process is timeout-bounded. These are **functional
gates, never hosted speed/energy measurements**.

**Exact code-source qualification:** commit
[`f78f4e3590e0f50397d1b16f84ac7f52b42f3843`](https://github.com/alex-1974/concurrency-d/commit/f78f4e3590e0f50397d1b16f84ac7f52b42f3843)
and [GitHub Actions #38716417126](https://github.com/alex-1974/concurrency-d/actions/runs/38716417126).
The P19 step completed successfully under pinned DMD 2.111.0 and
LDC 1.41.0. The complete P01–P18 matrix and the precise workflow
result must also be checked before claiming branch-wide CI success.
An earlier compile-only attempt (CI #38716326218) exposed D's
`opCall` aggregate-construction ambiguity; explicit struct field
initialization fixed only the test fixture.

## P20 native-state follow-up

[P20](../p20_owned_native_unknown/README.md) introduces a **synthetic
pre-native-join** fault on a source-pinned research copy of the **real**
M0 `OwnedTaskExecutor`. It observes `isStopped()==true` while the
accepted worker remains blocked and its owned record retained, then
requires a separate supervisor-rooted *actual successful join* before
cleanup. This does **not** reproduce an actual failed native join or
promote P19's normal lifecycle evidence into a general fault-tolerant
`@safe` executor. The false-state finding motivates a distinct
`shutdownUncertain` versus verified `joinedStopped` design gate.

## Decision and limits

**KEEP (research):** concrete evidence for ordinary accepted GC-backed
`GraphTask` callables on the **real** M0 executor under one blocked worker,
forced collections, handles abandoned, exact obligations, post-dispatch
reclamation and independent result-cell observation.

**NO-GO (release/public safety):** this does not justify generic
`@safe submit`, detaching caller-stack borrows, general
join/start failure recovery, GC collector correctness for arbitrary user
closures or production promotion of a storage policy. P07/P08's native
failure and executor-abandonment concerns remain unresolved; the test
assumes ordinary successful join and an independently live executor.
Nor does the new evidence supply semantically fair native LDC/C++
performance data.

Retain **ADR-0001 PROPOSED**, **Issue #17 OPEN** and **PR #38 Draft**.
Keep `source/`, `develop`, `main`, and grandfathered PR #35 unchanged.
