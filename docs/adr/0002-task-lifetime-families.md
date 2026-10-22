# ADR-0002 — Separate owned tasks from scope-bounded tasks

- **Status:** Proposed for v0.2; safety boundary selected, release acceptance pending
- **Issue:** [#17 — task lifetimes and storage boundaries](https://github.com/alex-1974/concurrency-d/issues/17)
- **Research basis:** [pinned M1 lifetime corpus](https://github.com/alex-1974/concurrency-d-research/tree/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9/research/m1_task_lifetime)

## Context

The scheduler transports an eight-byte, non-owning `TaskRef`. It does not own
the record it points to. The v0.1.0 `Executor` retains accepted task records,
but its `@system` submission API cannot prove that an arbitrary callable owns
everything reachable through its captures. Callers must keep borrowed
referents alive through `closeAndJoin` and synchronize shared mutable state.

The M1 research corpus contains DMD/LDC compile probes and bounded P01–P03
scope prototypes. These establish useful mechanisms, not a general `@safe`
concurrent borrow API or a performance win. P08/P09 also show that allocating
a callable on the GC heap does not make pointers inside it owned.

### Storage evidence and current disposition

The [P12 matched storage study](https://github.com/alex-1974/concurrency-d-research/blob/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9/research/m1_task_lifetime/prototypes/p12_matched_pool/README.md)
compares caller-stack and contiguous GC arrays of the same records on the same
`TaskRef` scheduler, with equal work and a post-dispatch join before reuse. It
does not measure the public `OwnedTaskExecutor` or `TaskScope` task-node costs,
arbitrary closure GC graphs, or a reusable record pool. Its recorded XPS session
is explicitly insufficient to select a general production strategy. The
in-repository [`benchmarks/storage`](../../benchmarks/storage/main.d) diagnostic
now adds a reused fixed GC slab and fresh-GC-per-wave arm to the same raw
`TaskRef` comparison. One local XPS session measured 2,048 and 16,384 records,
1/2/4 workers, three waves, and seven paired samples per configuration. All
42 measured triples passed equal-checksum and cyclic-order checks. The median
paired total-time differences were mixed: fresh GC versus stack ranged from
−836 μs to +214 μs and won 3–4 of seven pairs per configuration; reused GC
versus stack ranged from −740 μs to +86 μs and won 1–5 pairs. Package
temperature varied from 56°C to 78°C during the run, and workers were not CPU
pinned, so this single-machine session is diagnostic only. It still does not
measure generic owned nodes, closures, or public `TaskScope` costs. Keep current
GC-owned nodes as the baseline; neither stack placement nor pool reuse is
approved for production. A pool candidate must preserve GC reachability and
prove that records are reset only after the post-dispatch return marker.

## Proposed direction

Keep two lifetime families distinct. They may share the scheduler transport,
but their storage and completion obligations differ.

### Independently owned tasks

- An owned submission may outlive the submit call and dropped result handles.
- The executor must keep the task record and every referent needed by the task
  strongly reachable until the worker has stopped accessing them. Copying a
  pointer, delegate, slice, or class reference is not proof of ownership.
- The current general callable API remains `@system`; its existing caller-side
  lifetime and synchronization requirements remain in force.
- A future `@safe` transfer overload must accept only a representation whose
  ownership rules are established by the type/API and external positive and
  negative compiler probes. Do not infer deep ownership from a copied value.
- Full GC-backed records remain the baseline until an equivalent-lifetime
  measurement justifies another storage strategy.

### Scope-bounded tasks

- A scope may borrow caller data only while it retains every accepted task's
  record and referents, and does not return until every published task is
  quiescent after dispatch.
- The scope has no detach operation. Dropping an individual result handle or
  requesting cancellation does not discharge the scope's join obligation.
- Records must have stable addresses after publication and cannot be reused,
  moved, or destroyed until no worker can access them. Result readiness alone
  is not that proof.
- On ordinary callback failure, the scope drains all accepted children before
  reporting failure. Cancellation is a cooperative request, never permission
  to reclaim a running record.
- Begin with an explicitly joined lexical API. A destructor-only join is not
  sufficient evidence for safe unwind or worker self-join behavior.
- The API remains `@system` until compiler checks against the actual consumer
  API and runtime lifetime tests justify a narrower safety boundary. D's
  `scope`/DIP1000 checks reject selected escapes; they do not prove transitive
  closure ownership, race freedom, or a correct cross-thread join protocol.

The common lifetime progression is:

```text
prepared → published → claimed → executing → result ready
         → dispatch returned / no worker access → reclaimable
```

The scope's borrowed storage may leave scope only after the final state. For
owned work, the executor's strong ownership remains until that same quiescence
point or another separately proven lifetime mechanism.

### Compiler evidence and safety decision

The public validation gate now builds the actual external API with DIP1000
explicitly enabled. Its positive probe passes a stack pointer through a copied
callable in an `@system` scope and verifies that the joined child updates it
before scope return. The negative probes establish that `@safe` callers cannot
invoke `submit`, `withScope`, or `join`, and that `TaskScope`'s disabled copy
constructor rejects an ordinary value escape. D's explicit `move` can still
reset the callback's public `TaskScope` view. The mandatory join therefore
lives in a separate internal state retained directly by the `withScope` frame;
moving the view cannot move or drop that obligation. The external runtime gate
moves a view, spawns through it, and verifies completion before scope return.

A separate compile-only limitation probe deliberately stores `&tasks` from the
scope callback in a global `TaskScope*`. DMD 2.111 and LDC 1.42 both accept that
code with DIP1000 enabled because the boundary is `@system`. Executing the
escaped pointer would be invalid. DIP1000 also cannot prove transitive ownership
of pointers, slices, delegates, class graphs, or shared mutable state inside a
copied callable.

Therefore the v0.2 candidate keeps `Executor.submit`, `Executor.withScope`,
`Executor.join`, and `TaskScope.spawn` as `@system`. No general `@safe` or
`@trusted` forwarding overload is admitted. The safe claim is narrower:
`withScope` enforces runtime draining of every accepted child through its
post-dispatch return, while the caller remains responsible for valid captures
and synchronization. `CancellationToken` observation/request methods remain
`@safe` because they only access their shared atomic request state.

## Failure boundary

A failed or uncertain native join does not prove worker quiescence. A borrowed
scope must not return and destroy its caller-owned records while a worker may
still hold a `TaskRef`. The existing process-fatal native-lifecycle policy
remains the only accepted v0.1.0 behavior; research models of an
`shutdownUncertain` state do not establish recoverable native join failures.

## Consequences and exclusions

This separation permits truthful comparisons between storage strategies with
the same lifetime semantics. It costs a real join barrier for borrowed work and
one internal scope-state allocation. It does not prevent deadlocks when a child
blocks on work that only the exhausted same pool can execute.

The current branch now contains an experimental public `TaskScope` entrypoint,
and a cooperative `CancellationToken` prototype. A cancellation request is a
pollable signal only: it does not interrupt work, auto-cancel siblings on task
failure, replace the callable's one result/error outcome, or discharge the
scope's post-dispatch join. Token copies share the request state; they are not
independent observer subscriptions. The public gate covers request-before-
publication, queued and running children, 64 completion races, and 16 shutdown
races. This proposal does not
approve either prototype as a stable API or authorize arbitrary `@safe`
submission, helping for ordinary `TaskHandle.get()` waits, a cancellation
hierarchy, a new scheduler policy, or stack/pooled storage for detached owned
work. Scoped joins currently include bounded same-pool helping; its progress and
contention behavior still require runtime qualification.

The two-way `Executor.join` prototype schedules one branch and evaluates the
other inline. The in-repository `benchmarks/fork-join` diagnostic compares it
with a two-child scope and explicit `submit + get`; all three variants run
inside a driver task so the worker budget is equal. One local XPS/LDC 1.42
session used 256 sequential pairs, four workers, 2,048 kernel iterations, three
warmups and nine rotated measured samples. All checksums matched. Median times
were 1.192 ms for `join`, 2.124 ms for the two-child scope, and 2.857 ms for
explicit submission; `join` was lower in all nine samples. Package temperature
rose from roughly 53°C to 66°C, workers were not pinned, and this was one
machine/session. The result supports retaining the small helper for further
qualification; it is not a general speedup claim or a Rayon comparison.

## Gates before acceptance

1. Add positive and negative external consumer probes against the actual
   proposed API using pinned DMD and LDC with DIP1000 enabled where applicable.
2. Exercise bounded and dynamic scope publication, worker return, dropped
   handles, ordinary exceptions, cancellation requests, GC-visible captures,
   destruction ordering, and shutdown races. Cover every behavior the API
   exposes; keep unsupported cases explicit.
3. Demonstrate that no normal scope exit can occur before all task records are
   quiescent, including error unwinding. Keep unsafe casts and synchronization
   wrappers narrowly bounded and reviewed.
4. Only then decide which overloads, if any, can be `@safe`. Measure storage
   alternatives only within equivalent ownership and completion semantics.

Until these gates pass and the maintainer accepts the decision, this ADR is a
design proposal. The v0.1.0 public API remains unchanged.

Current gate disposition:

1. Positive, negative, and compile-only limitation probes run against the
   external API with DIP1000 under DMD and LDC. They support the `@system`
   decision and reject a general `@safe` claim.
2. Runtime coverage includes bounded runtime publication, nested/recursive
   groups, value/void results, dropped handles, task/body failures, cooperative
   cancellation, GC-visible callable graphs, and concurrent shutdown.
3. Normal return and unwind both wait for the post-dispatch return marker;
   worker-side recursive helping and shutdown races exercise that fence.
4. GC-backed address-stable owned nodes remain the selected baseline. The
   matched raw-record diagnostics and the public-path closure/GC-graph study
   in [ADR-0005](0005-keep-gc-owned-task-records.md) do not justify stack or
   pooled production records. Deterministic callable destruction timing is
   explicitly not part of the API; reclamation removes strong roots only after
   worker quiescence.

The local technical gates are satisfied for the provisional API. Native CI and
maintainer release acceptance remain part of Issue #23 rather than grounds for
claiming this proposal is already a released contract.
