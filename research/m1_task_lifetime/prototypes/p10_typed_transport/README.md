# M1 P10 — Typed inline value tasks via the actual M0 TaskRef transport

**Date:** 2026-10-13  
**Status:** research correctness **PASS** for the explicitly tested typed transport and consumer. **NO-GO for promoting a general public @safe worker API.**  
[Issue #17](https://github.com/alex-1974/concurrency-d/issues/17) · [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md) · [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38) · [P09 type/lifecycle precursor](../p09_transfer_contract/README.md).

## Research question and exact boundary

Can D compile-time-specialize **both** input and output types, exclude captures that might refer to caller stack storage, and execute useful work on native workers via the **existing M0 one-word non-owning TaskRef and dispatchTask** without introducing a new virtual base class or type-erased result cell?

**For a bounded synchronous, fixed-array research case: yes.** This implementation compiles the actual unmodified [source/concurrency/internal/task_record.d](../../../../source/concurrency/internal/task_record.d) into a linked executable, and uses its real `TaskHeader`, `TaskRef` and `dispatchTask` calls across two native worker threads. The consumer exercises different input and result types including structs and nested fixed arrays.

**Important distinction:** P10 uses a small **separate bounded FIFO** to isolate the typed transport. It does **not** execute the real M0 `SubmissionWorkerPool`/work-stealing deques, and does not inherit their scheduling, parking, throughput, or shutdown guarantees. The real pool has outstanding P06/P07 native lifecycle issues, so a successful P10 transfer is not a release qualification of that scheduler.

## Actual D typed interface (research-only, not API freeze)

[Implementation: m1_typed_transport.d](concurrency/research/m1_typed_transport.d)

```d
// Only P09-approved inline representations may cross this entrypoint.
struct InlineResults(R) if (isInlineTransfer!R)
{
    size_t count;
    R[8] values;
}

InlineResults!R evaluateInline(P, R)(
    scope P[] input,
    R function(P) @safe pure nothrow @nogc operation) @safe
    if (isInlineTransfer!P && isInlineTransfer!R);
```

The consumer passes a function **pointer**, not a delegate carrying captured context. The callable must be `pure @safe nothrow @nogc`, and both P and R must satisfy the conservative recursive P09 whitelist: primitive values, fixed arrays and nonnested POD structs consisting only of qualifying fields.

The code copies all input values into an inline stack array before creating any worker. A zero- or one-element call remains entirely inside compiler-checked `@safe` code without invoking the trusted scheduler. Larger calls are synchronous: all accepted records are fully joined before any result leaves the call frame.

## Implementation and relevant invariants

- `TypedRecord!(P,R)` holds **TaskHeader first**, followed by a typed context-free operation pointer, copied P, and R result. The record template provides a specialized static `execute` thunk; the thunk performs typed `record.operation(record.input)` with no virtual method or runtime cast of P/R to an erased value object.
- `@disable this(this)` rejects ordinary copies of the published records. The implementation stack-pins a bounded eight-record array for the entire worker lifetime. It does not license arbitrary bytewise movement through @system code.
- A worker receives a one-word `TaskRef` pointing to a prepared record and invokes the **unchanged** `dispatchTask`. The thunk and function pointer remain indirect calls; P10 does **not** claim zero indirect dispatches. No per-task `OwnedNode`, `TaskHandle`, or `ResultCell` allocation occurs in this research variant.
- The bounded `WorkerQueue` owns its synchronization objects and two native `Thread` instances and serializes ingress under one mutex. This prototype *does allocate/start/join threads per parallel call*. Thus even if task records are stack-allocated, it is **not** zero-allocation end-to-end.
- Each task writes only to its own typed record. Input values are copied before publication; result values are read only after all workers have genuinely joined. A completed R value by itself is not a safe substitute for a native worker join.
- For a worker `Throwable` returned after successful `join(false)`, P10 joins all started workers before propagating the failure, consistent with P06. Pending work may be unexecuted after a fatal worker Error; failed execution does not return an apparently valid `InlineResults`.
- **Native start/join uncertainty:** this research kernel uses a conservative `abort()` fail-stop rather than allowing a caller-frame unwind if `Thread.start()` throws (including a possible post-native-launch `ThreadError`) or if a native `Thread.join(false)` operation itself throws. That severe policy is a research safety fallback from P07; no actual native OS error was injected or qualified **in P10**. Thread/mutex/condition implementation errors outside the modeled paths and total trust soundness remain OPEN.
- The `@safe` entrypoint crosses a **private, manually assumed @trusted** `runCopied!(P,R)` lifecycle, plus a small `@trusted` shared-header-to-record cast inside the specialized thunk. Both trust annotations were independently challenged as `@safe` by recompiling the actual research source: both DMD/LDC reject for the intended system-call/borrow/cast reasons. **Compiler rejection establishes the trust boundary is necessary; it does not prove that the manually trusted implementation is sound.**

### Concrete attributes/capture contract

The API rejects class references, raw pointers, slices, nested POD fields containing pointers or delegates, and arbitrary closure delegates. This is an intentionally limited transfer representation: it is **not** a general classification of owned D graphs or a guarantee that arbitrary user-authored `@trusted` code cannot launder a numeric address. A `pure @safe` callback still cannot make the library prove the correctness of unrelated user-authored trusted functions it might call. Move-only capture types and independently retained heap objects are **out of scope**.

## Real external consumer and negative compiler fixtures

The external positive test [positive_typed_consumer.d](consumer/positive_typed_consumer.d) imports the same P10 module as all negative fixtures and invokes `evaluateInline` from an **explicitly @safe** function.

It tests:

- `Point2` POD inputs returning different POD `Cell` outputs (four records);
- `Nested` structs containing fixed arrays returning `long` (two native worker records);
- 32 consecutive full batches of eight `int` records (correctness/reuse only; not a throughput benchmark);
- the returned value's independence from later input mutations;
- zero and singleton fast paths;
- too-large input and null operation rejection before worker creation.

The **seven separate, real-interface compile-negative** consumer fixtures must fail the actual constrained `evaluateInline` call. Both pinned compilers' logs were inspected for the right template overload/call diagnostics, not just a nonzero return:

| Negative file | Rejected candidate |
|---|---|
| `negative_borrowed_pointer.d` | raw pointer as P |
| `negative_borrowed_field.d` | POD struct embedding a pointer as P |
| `negative_slice_input.d` | dynamic slice as P |
| `negative_class_result.d` | class reference as R |
| `negative_delegate_operation.d` | captured-context delegate instead of function pointer |
| `negative_unsafe_operation.d` | function pointer that is @system |
| `negative_nonpure_operation.d` | function pointer missing pure |

The runner also creates two temporary **modified real-source** compiler challenges, independently replacing the `runCopied` and specialized `fromHeader` trust marker with `@safe`. Both compilers reject the actual record frame escape/system worker operations and the shared-header cast respectively. These tests do not turn the unsafe core into compiler-proven safe code.

## Qualification

**Exact initial implementation/runner/workflow source commit:** `3b10d0097dbfcc7d7a46fedbf0f0c28742da180e`.

**[GitHub Actions run #38401394397](https://github.com/alex-1974/concurrency-d/actions/runs/38401394397): PASS** — DMD 2.111.0 job `115309652813`, LDC 1.41.0 job `115309653297`.

Both jobs compile and run the external safe consumer, check all seven compile-negative consumers with intended errors, and execute both `@trusted`-to-`@safe` marker challenges. LDC runs the same positive consumer additionally with **`-O3` and assertions enabled**. All P01–P09 research gates and inherited DIP1000 probes pass in this workflow.

From repository root:

```sh
bash tools/research/m1_typed_transport_prototype.sh dmd
bash tools/research/m1_typed_transport_prototype.sh ldc2
```

## Cost analysis — structural evidence only

| Property | P10 specialized synchronous typed batch | Existing M0 OwnedTaskExecutor |
|---|---|---|
| Task transport | Actual one-word M0 TaskRef | Same M0 TaskRef |
| Callable dispatch | Header thunk + typed function pointer; no virtual class dispatch | Header thunk + specialized OwnedNode(F,R) callable invocation |
| Record/payload storage | Up to 8 private stack-pinned POD records per call | Per-admission GC-allocated OwnedNode with callable/cell and bounded RetainedTask[] roots |
| Result storage | Inline R[8] in call result, available after all joins | Per-submit ResultCell + TaskHandle, independently awaitable |
| Thread lifecycle | **Two new native threads per multi-task call** | Long-lived worker pool after executor construction |
| Queue model | Small mutex FIFO, not the production work-stealing engine | M0 ingress plus owner/thief work-stealing deques |
| Ownership/feature semantics | Synchronous, no escape, by-value-only, bounded eight | Independently awaited typed handles, user-callable F, multi-producer, explicit close |
| Full lifetime guarantee | Still manually trusted worker/native failure protocol; fail-stop when uncertain | Outstanding native shutdown / capture-ownership concerns identified in P06–P09 |
| Current benchmark verdict | **NONE — correctness/structural comparison only** | Not compared on semantically matched work in P10 |

There is **no fair performance verdict** between these different APIs: P10 changes work lifespan, worker startup, allocation/retention, result accessibility and scheduler model. An optimistic timing comparison would violate workspace policy (`faster + weaker semantics != optimization`). P10 demonstrates a **possible reduction in per-task storage/indirection/virtual dispatch only by specializing a much narrower operation family**, not a measured executor speedup.

**NEXT:** benchmark comparable kernels on a **shared worker runtime and equivalent ownership/close semantics** (or explicitly label microkernel-only dispatch analysis). Independently qualify and reduce the trusted worker lifecycle, including post-native-launch errors and whether the application can tolerate process-wide fail-stop.

## Decision

**KEEP:** direct real-M0 TaskRef transport for specialized P/R inline data; actual @safe typed consumer and seven rejected misuse cases; bounded stack record lifetime through normal joins. No public contract freeze.

**NO-GO:** claiming generalized @safe scoped borrowing, arbitrary owned-closure transfer, native join failure recovery, release-quality @trusted proofs, performance parity/superiority to C++, or a merge to develop. Keep ADR-0001 PROPOSED, Issue #17 OPEN, draft PR #38 open, and grandfathered R0.5 PR #35 untouched.
