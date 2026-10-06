# R0.1 P08h — Taskflow Scheduler-Level Performance Comparison

## Status

P08h compares the preferred P08e marked-top batch candidate against:

1. the workspace D single-steal bounded work-stealing deque;
2. Taskflow `tf::BoundedWSQ`;
3. the same scheduler-like owner/thief workload.

The purpose is to separate language/toolchain performance from architectural
batch-transfer performance.

Taskflow is pinned at:

    bbd7251d577b33a4aeff434ce5f5569b94d4cc48

The comparison is research evidence, not a general claim that D is faster than
C++.

## Workload

All variants use:

    capacity    = 2^20
    items       = 1,048,576
    thieves     = 4
    owner CPU   = 2
    thief CPUs  = 3,4,1,5
    warmups     = 4
    samples     = 15

The queue is prefilled.

The owner repeatedly pops from the bottom.

Thieves steal from the top.

Each returned item performs identical deterministic local work with:

    work = 0
    work = 16
    work = 64

The returned values and work results are checksum-qualified.

The comparison is performed as four alternating D / C++ runs to reduce
temporal drift.

## P08h0 — Taskflow scheduler-like reference

Taskflow uses:

    tf::BoundedWSQ<size_t, 20>

and ordinary one-item `steal()`.

The scheduler-like workload was implemented to match the D P08e5 harness as
closely as possible:

- same prefill;
- same item count;
- same owner CPU;
- same four thief CPUs;
- same task payload;
- same warmup/sample counts;
- same checksum accounting;
- same owner-versus-thief drain semantics.

## P08h1 — Paired comparison

Median-of-run medians:

### work = 0

    Taskflow single   = 69.174 ns/item
    D single          = 63.221 ns/item
    D P08e batch-8    = 15.915 ns/item

D single versus Taskflow:

    -8.61 %

P08e batch versus Taskflow:

    -76.99 %

Equivalent speedup:

    Taskflow / P08e = 4.35x
    D single / P08e = 3.97x

Median owner shares:

    Taskflow = 47.286 %
    D single = 49.680 %
    P08e     =  1.158 %

### work = 16

    Taskflow single   = 72.340 ns/item
    D single          = 67.941 ns/item
    D P08e batch-8    = 17.947 ns/item

D single versus Taskflow:

    -6.08 %

P08e batch versus Taskflow:

    -75.19 %

Equivalent speedup:

    Taskflow / P08e = 4.03x
    D single / P08e = 3.79x

Median owner shares:

    Taskflow = 43.675 %
    D single = 46.322 %
    P08e     =  7.287 %

### work = 64

    Taskflow single   = 69.559 ns/item
    D single          = 68.858 ns/item
    D P08e batch-8    = 33.721 ns/item

D single versus Taskflow:

    -1.01 %

P08e batch versus Taskflow:

    -51.52 %

Equivalent speedup:

    Taskflow / P08e = 2.06x
    D single / P08e = 2.04x

Median owner shares:

    Taskflow = 27.715 %
    D single = 28.149 %
    P08e     = 18.581 %

## Interpretation

The D single-steal implementation and Taskflow are in the same performance
class under this scheduler-like workload.

Across the paired runs, D single-steal ranges from approximately parity to
about 9 % faster than Taskflow.

This is evidence that the ordinary D work-stealing deque reaches established
C++ implementation performance on this host and workload.

The much larger P08e result must not be attributed to D versus C++.

P08e changes the scheduling mechanism:

    single steal:
        one atomic top claim per item

    P08e batch-8:
        one marked top reservation
        up to eight items transferred locally

The batch design therefore amortizes top contention and synchronization across
multiple tasks.

The benefit is largest when task-local work is small:

    work=0   ~4.35x versus Taskflow
    work=16  ~4.03x versus Taskflow
    work=64  ~2.06x versus Taskflow

As useful local task work grows, queue-coordination overhead becomes a smaller
fraction of total execution time and the batch advantage naturally shrinks.

## Architectural conclusion

The R0.1 performance objective is met at two distinct levels.

### Baseline

The D single-steal implementation reaches approximately Taskflow-level
scheduler performance.

This means the implementation does not require a mechanical C++ port merely to
reach the established reference class.

### Specialized scheduler path

P08e demonstrates that a D-native, explicitly qualified batch-steal mechanism
can materially exceed the single-steal baseline for fine-grained workloads.

The measured gain comes from architecture rather than language identity.

P08e therefore remains the preferred R0.1 scheduler candidate.

## Limits

These results are specific to:

- Intel Core i7-9750H;
- x86_64;
- LDC 1.41.0 / LLVM 19;
- GCC 15 Taskflow reference;
- the pinned Taskflow revision;
- this fixed CPU topology;
- this scheduler-like workload.

They are not a universal D-versus-C++ performance claim.

Future qualification should repeat the comparison on additional architectures
and compilers.
