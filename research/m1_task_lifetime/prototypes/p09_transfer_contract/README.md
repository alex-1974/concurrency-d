# M1 P09 — Conservative inline-data transfer and supervised shutdown uncertainty

**Date:** 2026-10-13  
**Status:** bounded research, not a production public API.  
**Related:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38), [P08 owned-vs-borrowed](../p08_owned_vs_borrowed/README.md).

## Goal: do not confuse copied representation with transitive ownership

The current production-source OwnedTaskExecutor stores a GC-owned task record, but still admits an arbitrary caller-supplied F with @system trySubmit. Such an F may hold borrowed pointers, dynamic slices, delegates and class references. Merely allocating the enclosing record on the GC heap is **not** a proof of ownership or safe cross-thread transfer.

P09 explores two intentionally separated contracts:

1. **Restricted structural representation**: a compile-time-only, conservative **inline data** whitelist for snapshots of primitive scalars, fixed-size arrays, and nonnested plain POD structs whose individual fields themselves meet the whitelist.
2. **Shutdown liveness**: an independently rooted controller/supervisor model with distinct `running`, `draining`, `shutdownUncertain`, and `joinedStopped` phases; an uncertain worker never licenses record/payload reclamation.

Neither experiment uses the real production worker pool or offers a callable/task scheduler API. The trait tests *representation*, not whether arbitrary computations or captured object graphs are safe, and the supervisor tests *model semantics*, not native OS join recovery.

## 1. Actual D compiler-enforced representation contract

[Research module: `concurrency.research.m1_inline_transfer`](concurrency/research/m1_inline_transfer.d)

The templated predicate `isInlineTransfer!T` uses the D built-in `__traits(isPOD, T)`, `std.traits.Fields!T`, `std.traits.hasNested!T`, and recursive template matching of fixed arrays. The actual external `@safe` consumer checks that copied original values do not alias the recipient representation, including nested POD structs containing arrays.

**Initially supported:** the explicitly enumerated primitive types (bool, integer, floating and character scalars), recursive fixed arrays of those values, and *nonnested POD structs* composed only of supported field types. We avoid overgeneralizing to arbitrary unions, enums, all scalar/vector types or generated D copy operations; these are **not** all qualified here.

**Intentionally refused:** raw pointers, dynamic slices (even slices of immutable data), class references, delegates/closure contexts, function pointers, associative arrays, nontrivially copied/destructed structs and nested struct hidden context pointers. This is a conservative **sufficient subset**, not the definition of independently owned heap data.

**Important semantic bound:** a POD struct can still contain numeric addresses in integer fields (or user code may manufacture pointers using casts). No purely structural whitelist can defeat intentional laundering through @system/@trusted code. P09 accepts no user callbacks at all. D's compiler ensures the specific constrained `snapshotInline` call from `@safe` code compiles or is rejected; it does **not** magically guarantee that a future executor has safe lifetime and threading behavior.

### Actual external fixture gate

The separate [positive consumer](consumer/positive_inline_consumer.d) calls `snapshotInline` from an explicitly `@safe` function, verifies copied nested structs and arrays, and statically checks both accepted and rejected representations.

Six **compile-negative** external files import the *same module* and try the actual forbidden function call. Both DMD and LDC logs were checked to fail at the intended constrained `snapshotInline` overload, not from unrelated code:

| Negative fixture | Declared rejected representation |
|---|---|
| `negative_raw_pointer.d` | raw int pointer |
| `negative_slice.d` | dynamic integer array/slice |
| `negative_borrowed_member.d` | POD record embedding a raw pointer |
| `negative_delegate_member.d` | record embedding a delegate |
| `negative_class_ref.d` | GC class reference |
| `negative_function_ptr.d` | even context-free function pointers (not part of this **data** whitelist) |

The first compilation failed under DMD because `isPOD` is a **built-in compiler trait**, not an importable `std.traits.isPOD` template. The implementation was corrected to `__traits(isPOD, T)`. Preserve that initial failure as toolchain-specific research evidence: [workflow run #38398631118](https://github.com/alex-1974/concurrency-d/actions/runs/38398631118). The corrected type trait and full gate passed [workflow run #38398861625](https://github.com/alex-1974/concurrency-d/actions/runs/38398861625), DMD 2.111.0 and LDC 1.41.0 including LDC `-O3` assertions-on correctness.

## 2. Explicit supervised uncertain-shutdown states

[Research model: `concurrency.research.m1_uncertain_supervisor`](concurrency/research/m1_uncertain_supervisor.d)

This *separate* test has a GC-owned integer ValueNode, worker Thread, synchronization Gate, and independently rooted Supervisor. The worker performs a multiplication by four, deliberately remaining blocked while a simulated join failure occurs:

1. A worker starts, and the controller waits for it to enter a synchronization gate.
2. The model transitions `running → draining → shutdownUncertain` and throws an **injected** Exception **without invoking native pthread_join**.
3. The consumer explicitly drops its controller handle. Supervisor retains the Lease/ValueNode, including across four forced GC collections.
4. Releasing a supervisor lease while state is `shutdownUncertain` is **rejected**, preserving its root.
5. The test opens the gate and obtains a **real successful native `Thread.join(false)`**, changing state to `joinedStopped`.
6. Only now is Supervisor permitted to remove the lease/root. Sixteen additional independently created leases repeat the release sequencing.

**Critical nuance:** successful second join after a simulated error does **not** prove that a genuine failed native join can be safely retried. This is a lifecycle **state/retention** test, not a native failure recovery or high-availability guarantee. An alive supervisor is a precondition here; the model does not prove executor survival if *every* independent owner abandons its roots, nor an architecture for persistent supervisor services.

### Evidence / reproduction

Run from repository root:

```sh
bash tools/research/m1_inline_transfer_and_uncertain.sh dmd
bash tools/research/m1_inline_transfer_and_uncertain.sh ldc2
```

The runner uses the real P09 modules, an external consumer, six compile-negative fixtures, the separate supervised Thread model, and a 20-second test timeout. LDC additionally runs the positive consumer and the supervisor with `-O3`, preserving assertions.

The initial correction gate [#38398861625](https://github.com/alex-1974/concurrency-d/actions/runs/38398861625) passed both pinned compilers. A final follow-up tests explicit **early-release rejection** of an uncertain lease and is qualified by the latest P09 workflow. Do not infer optimized throughput/latency from these correctness tests or compare this model to the production work-stealing pool.

## 3. Ownership/failure decision matrix

| Question | Constrained inline value | Arbitrary owned heap-node callable | Borrowed lexical task |
|---|---|---|---|
| Can field representation contain borrowed references? | **Rejected structurally** for qualified finite whitelist | Yes: arbitrary F may contain borrowed pointers/delegates | Yes, intentionally |
| Does record's heap allocation prove capture ownership? | Not needed for the primitive snapshot; record handled separately | **No** | **No** |
| If task's result is ready, has worker ceased all accesses? | Not implied | Not implied | Not implied |
| If native join fails, can caller unwind the borrowed scope? | No such borrow is passed by this data-only interface; still need independent worker retention | Only when *entire* payload/worker graph remains safely rooted; progress unproven | **NO-GO** for normal unwind without a proven join |
| If caller drops its result/controller handle during uncertainty? | Ownership still needs a separate worker/supervisor root | Must have explicit retained owner independent of handle | Stack lifetime cannot be extended by naming a supervisor |
| When may retained task payload be discarded? | After actual quiescence/owned lifetime proof | After actual quiescence or other separately proven safe retention protocol | After **all** workers that can access borrows have actually quiesced |

**P09 KEEP:** a structurally checked, narrow data-only transfer family and a separate, independently rooted `shutdownUncertain` state model.

**P09 NO-GO:** generalizing this to an arbitrary `@safe` `OwnedTaskExecutor`; claiming that copying a pointer-rich callable makes it owned; treating join failure as a normal successful stop; inferring any real failed-native-join recovery; promoting arbitrary borrowed captures into `@safe TaskScope`.

## Next technical gate

A viable P10 would either:

- design a typed **operation + inline-data payload** pair that is actually passed to the real M0 dispatcher without accepting arbitrary closure captures, and qualify that narrower consumer contract; or
- separately design a supervisor-rooted runtime owner for the existing owned executor's entire reachable task graph, including the native post-start exceptional state and shutdown error transitions, with stress and destructor tests.

These are distinct efforts. Do not combine them into a falsely general `@safe` API or a performance comparison with weaker semantics. Keep Issue #17 OPEN, ADR-0001 PROPOSED, Draft PR #38 DRAFT, the grandfathered R0.5 branch and `develop` unchanged.
