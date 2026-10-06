# R0.1 — Work-Stealing Deque

## Goal

Determine the work-stealing deque design suitable for the first
high-performance CPU scheduler in concurrency-d.

The research compares mechanisms, not APIs.

## Primary references

- Taskflow bounded work-stealing queue
- Taskflow unbounded work-stealing queue
- Chase-Lev work-stealing deque
- Crossbeam deque
- Rayon scheduling use of work stealing
- Tokio local run queue and batch stealing

External implementations are references and benchmark controls, not the
specification of concurrency-d.

## Initial questions

1. Can a bounded Chase-Lev deque provide the best local hot path?
2. Should the owner cache `top` to avoid repeated cross-core loads?
3. Is steal-one or batch-steal preferable for representative workloads?
4. What should happen when the bounded local deque fills?
5. What memory-ordering is required for correctness on weakly ordered CPUs?
6. Should the scheduler queue carry one pointer or a two-word TaskRef?
7. Which layout minimizes false sharing?
8. Can the queue hot path remain `@nogc`, `nothrow`, and narrowly `@trusted`
   or fully `@safe` at its public/internal boundary?

## Variants

### A — bounded baseline

Direct D adaptation of the bounded Taskflow/Chase-Lev mechanism.

Expected shape:

- fixed power-of-two capacity;
- owner push at bottom;
- owner pop at bottom;
- thieves steal at top;
- CAS only for steal and last-item race;
- separate cache lines for contended indices.

### B — cached-top bounded

Variant A plus owner-private cached `top`.

Purpose:

Avoid an acquire load of `top` on every successful push when the queue has
ample free capacity.

### C — batch steal

Variant A/B with batch transfer from victim to thief-local queue.

Compare:

- steal one;
- steal half;
- bounded batch, e.g. maximum 32.

### D — overflow strategy

Keep the local deque bounded and compare overflow paths separately rather
than resizing the local hot structure.

Candidate strategies:

- sharded spill queues;
- global injection queue;
- hybrid.

## Non-goals

R0.1 does not define:

- public Task API;
- Executor API;
- TaskScope API;
- fibers;
- I/O scheduling;
- cancellation semantics;
- final worker parking strategy.

Those depend on later research.
