# R0.1 P08g3–P08g6 — Full64 Scheduler Performance Reassessment

## Status

P08g Full64 is no longer the preferred R0.1 work-stealing deque candidate.

P08e marked-top remains the preferred scheduler-oriented research candidate.

The Full64 representation remains valuable qualified research evidence, but
its full-width counter domain has a measurable synchronization cost under
scheduler-like owner/thief contention.

## Background

P08g2d compared P08e and Full64 in a pure concurrent drain workload.

Normalized medians were effectively equal:

    P08e    = 0.2374
    Full64  = 0.2379

That result justified treating Full64 as performance-parity in that particular
workload.

P08g3 subsequently tested a more scheduler-like workload in which a thief
consumes its stolen batch locally before returning to the victim.

That workload exposed a repeatable difference.

## P08g3 — Scheduler-like local work

Four alternating P08e/Full64 paired runs were performed with:

    thieves = 4
    batch   = 8
    work    = 0, 16, 64

Median normalized results:

### work = 0

    P08e ratio       = 0.2654
    Full64 ratio     = 0.2894
    Full64 delta     = +9.04 %

    P08e owner share = 1.192 %
    Full64 owner     = 2.083 %

### work = 16

    P08e ratio       = 0.2616
    Full64 ratio     = 0.3137
    Full64 delta     = +19.91 %

    P08e owner share = 7.303 %
    Full64 owner     = 7.408 %

The nearly identical owner shares show that the performance difference is not
explained by a materially different owner/thief work split.

### work = 64

    P08e ratio       = 0.4717
    Full64 ratio     = 0.4709
    Full64 delta     = -0.15 %

    P08e owner share = 18.590 %
    Full64 owner     = 18.460 %

As task-local work grows, the queue coordination cost is amortized and the two
representations converge.

## P08g4 — Direct LDC x86_64 code-generation comparison

P08e and Full64 stealBatch wrappers were compiled into the same optimized
binary with stable extern(C) symbols.

Instruction summary:

    P08e:
        instructions = 80
        lock ops     = 2
        mov/lea/cmp  = 35
        branches     = 9

    Full64:
        instructions = 81
        lock ops     = 2
        mov/lea/cmp  = 36
        branches     = 10

The difference is structurally concentrated before the busy-claim CAS.

P08e can reject busy from topState alone:

    load topState
    test busy bit
    return if busy

Full64 requires:

    load topState
    load bottom
    subtract
    bounded-distance check
    return if not plausible idle

Both then use the same two expensive locked operations in the successful
claim path.

The raw instruction-count difference is therefore small, but Full64 adds a
shared read of the owner-mutated bottom cache line.

## P08g5 — Isolated busy-rejection cost

With bottom effectively stable and another batch held busy:

### LDC

    P08e    = 0.496 ns/op
    Full64  = 0.774 ns/op

Full64 is approximately 56 % more expensive.

### DMD

    P08e    = 1.782 ns/op
    Full64  = 2.078 ns/op

Full64 is approximately 17 % more expensive.

The absolute LDC difference is only about 0.28 ns per rejection, so this alone
does not explain the scheduler-level regression.

## P08g6 — Busy rejection with active owner contention

P08g6 holds a batch reservation active while an owner repeatedly performs the
speculative pop / busy rollback sequence.

This deliberately makes bottom an actively written cache line.

### LDC

    P08e    = 0.520 ns/op
    Full64  = 2.009 ns/op

Full64 is approximately 3.86x as expensive.

Aggregate owner busy retries during measured samples:

    P08e    = 1,782,806
    Full64  = 3,489,318

### DMD

    P08e    = 2.067 ns/op
    Full64  = 8.037 ns/op

Full64 is approximately 3.89x as expensive.

Aggregate owner busy retries:

    P08e    = 6,426,858
    Full64  = 12,118,702

## Mechanistic interpretation

The Full64 distance-marker representation cannot determine busy from topState
alone.

Because every 64-bit raw top value is a valid logical counter value, there is
no remaining independent state bit for busy.

Full64 therefore identifies state through the pair:

    (topState, bottom)

This requires a bottom observation before the busy-claim CAS.

Under owner contention, bottom is actively written by speculative pop and
rollback.

The additional Full64 read therefore creates coherence traffic on precisely
the cache line that the owner is modifying.

P08e avoids this interaction because its explicit marker bit permits busy
rejection from topState alone.

The P08g6 result shows that this is not merely an ALU/code-size cost.

It is a synchronization/cache-coherence property of the representation.

## Revised architectural conclusion

P08g remains correct and valuable research:

- full 64-bit modular domain;
- real ulong.max -> 0 wrap;
- forced-overlap correctness;
- RC11 positive/negative-control qualification;
- near-baseline owner hot path;
- pure-drain performance parity after ordering minimization.

However, scheduler-like workloads reveal a material cost when steals are
frequent relative to useful task work.

P08e therefore regains preferred status for the R0.1 scheduler candidate:

    P08e:
        63-bit modular top domain
        explicit busy state in topState
        cheap top-only busy rejection

    P08g:
        full 64-bit modular top domain
        distance-derived busy state
        requires bottom observation
        measurable coherence cost

Performance is a primary design requirement.

The theoretical benefit of preserving the final counter bit does not justify
a repeatable hot-path regression of approximately 9–20 % in light-work
scheduler scenarios.

## Next direction

Do not continue micro-optimizing the existing Full64 distance-marker design
unless a new representation removes the bottom dependency.

The next R0.1 performance work should use P08e as the scheduler candidate and
compare it against semantically equivalent C++ references.

Alternative full-width representations may remain future research, including
wider packed state or a differently coupled coordination mechanism, but they
must independently justify their synchronization and code-generation cost.
