# ADR-0005 — Keep GC-owned task records for v0.2

- **Status:** Accepted in v0.2.0
- **Issue:** [#20 — task-record allocation and recycling](https://github.com/alex-1974/concurrency-d/issues/20)
- **Related:** [ADR-0002](0002-task-lifetime-families.md)

## Decision

**KEEP** one address-stable GC class node per accepted owned or scoped task.
The executor roots each node through its worker's return from dispatch. A node
becomes reclaimable at that point; the retained-record budget triggers sweeps,
and shutdown clears any remaining roots.

**REJECT for v0.2** stack-resident records in the general owned-task family.
They cannot outlive submission or a dropped handle and therefore do not match
the existing lifetime contract. Scope-bounded stack records remain a possible
future specialization, but current evidence establishes neither sufficient
benefit nor a complete unwind/native-failure proof.

**DEFER** executor/worker-local recycling and slab/chunk allocation. Any future
candidate must retain transitive GC graphs, keep published addresses stable,
and reset a record only after the post-dispatch return marker. The matched raw
record measurements omit generic callable/result-cell construction and cannot
justify this added state machine.

**REJECT as unsupported input**, rather than silently copying, move-only or
nonassignable callables/results. `Executor` currently needs default storage,
copy construction and assignment. External compile-negative fixtures for both
callables and results enforce that boundary under DMD and LDC. A future transfer
API requires a separate ownership representation and benchmark.

## Evidence boundary

The maintained [`benchmarks/storage`](../../benchmarks/storage/main.d) test
compares the same raw `TaskRef` work across caller-stack, fresh GC-array and
reused GC-array placement. It supplies an equivalent scheduler/reuse-fence
diagnostic, but deliberately omits public generic task nodes.

The maintained
[`benchmarks/owned-storage`](../../benchmarks/owned-storage/main.d) diagnostic
uses only the public `Executor` path and covers three supported callable shapes:

- a tiny value capture;
- a 512-byte inline context;
- a small transitive graph of GC class references.

Its timed arm includes executor construction, task/result-cell allocation,
dispatch, completion reads, post-dispatch shutdown, dropping roots and an
explicit collection. Its retention arm blocks the only worker, drops every
measured handle, forces collection and samples `GC.stats.usedSize` before and
after retention while the executor holds the required roots for queued nodes
and graphs independently of the dropped handles. It reports producer-thread
allocation and phase timings separately. GC used-byte deltas are observations,
not thresholds: the collector may conservatively retain stack words, reclaim
unrelated unreachable objects and reuse existing pages.

Correctness gates additionally force collection while owned and scoped graph
handles are dropped, verify the graph after dispatch, exercise bounded-budget
reuse, and require the post-dispatch return marker before reclamation. DMD and
LDC run the external API gate; LDC release provides the optimized code path.

The raw-placement XPS results recorded in ADR-0002 were mixed and thermally
variable. They do not show a consistent end-to-end win for stack or reused-GC
storage. The smallest correct design is therefore the existing GC-owned node.

## Consequences

The selected representation has allocation and GC-scanning cost proportional
to accepted tasks, while `maxRetained` bounds the number of rooted records.
It provides the required stable address and dropped-handle reachability with a
small, reviewable lifetime protocol. This decision does not promise prompt D
destructor execution, a byte-level heap cap, arbitrary deep ownership for
`@system` captures, or a platform-general performance ratio.
