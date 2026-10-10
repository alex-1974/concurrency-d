# R0.2 P05 — Scheduler-neighborhood integration

Status: PASS

## Goal

Exercise the selected R0.2 task representation in scheduler-shaped workloads
on top of the production containers-d WorkStealingDeque without folding
allocator/pool research into the measurement.

Selected representation entering P05:

```d
struct TaskRef
{
    shared(TaskHeader)* ptr;
}

struct TaskHeader
{
    ExecuteFn execute;
}
```

Both TaskRef and TaskHeader are one machine word on the qualified 64-bit
targets.

## Qualified gate

Focused workflow:

```text
R0.2 P05 scheduler neighborhood
run #3
commit 319b42f9693cb9994f76c55b30db43f72315b56f
```

Platforms:

- DMD 2.111.0 / Linux x86_64;
- LDC 1.41.0 / Linux x86_64;
- LDC 1.41.0 / native Linux AArch64 / ARM Neoverse-N2.

All three workloads passed exact correctness checks on all three configurations.

## P05a — flat granularity scaling

Workload:

- 262,144 tasks;
- capacity 1024;
- batch size 8;
- work = 0 / 16 / 64;
- 1 / 2 / 4 workers;
- single-steal and batch-steal variants;
- P12 execute-inline overflow behavior retained.

Result: PASS on DMD, LDC/x86_64 and native AArch64.

The expected R0.1 policy shape remains visible:

- tiny work remains highly sensitive to steal/batch coordination;
- useful work can make batch transfer advantageous;
- the deliberately front-loaded producer still drives substantial inline
  overflow and is therefore not a pure queue-throughput benchmark.

Representative hosted LDC x86_64 medians:

```text
work0:
  single 1w   8.864
  batch  1w   8.878
  single 2w  12.499
  batch  2w  11.682
  single 4w  38.972
  batch  4w  39.531

work16:
  single 1w  32.477
  batch  1w  32.326
  single 2w  41.898
  batch  2w  35.892
  single 4w  82.021
  batch  4w  53.094

work64:
  single 1w 202.029
  batch  1w 203.209
  single 2w 166.658
  batch  2w 133.826
  single 4w 160.875
  batch  4w  91.533
```

These hosted values are not compared directly with the project XPS baseline.

## P05b — recursive fork/join

Workload:

- binary tree depth 18;
- 524,287 tasks per measured run;
- work=16;
- 1 / 2 / 4 workers;
- single and batch stealing;
- cold overflow path;
- exact accounting;
- zero overflow in the measured scheduler path.

Result: PASS on DMD, LDC/x86_64 and native AArch64.

Representative hosted LDC x86_64:

```text
single 1w 46.600 ns/task
batch  1w 46.333

single 2w 37.138
batch  2w 37.578

single 4w 63.356
batch  4w 63.500
```

Native AArch64:

```text
single 1w  40.214 ns/task
batch  1w  40.152

single 2w 103.734
batch  2w 103.667

single 4w 173.085
batch  4w 174.082
```

The architecture-specific scaling difference is retained as evidence rather
than normalized away.

## P05c — irregular graph

Workload:

- four workers;
- deterministic irregular graph;
- depth 18;
- 218,643 tasks;
- heterogeneous task cost;
- capacity 1024;
- batch size 8;
- exact execution/spawn/sum/xor/work-checksum validation;
- zero overflow.

Result: PASS on all three configurations.

Hosted LDC x86_64:

```text
single 51.878 ns/task
batch  53.015 ns/task
```

Native AArch64 / Neoverse-N2:

```text
single 214.055 ns/task
batch  215.227 ns/task
```

For context, the earlier R0.1 native-AArch64 P14c qualification on the same
runner class recorded:

```text
single 214.759 ns/task
batch  214.895 ns/task
```

The representation-integrated irregular workload is therefore in the same
performance class as the retained R0.1 value-handle scheduler evidence.

This comparison is used only as a regression signal on the same runner class;
it is not a broad language or machine benchmark claim.

## Semantic findings

P05 demonstrates that the selected pointer-only representation composes with
the production deque across:

- fine/medium/coarse flat scheduling;
- recursive task creation;
- irregular graphs;
- single and batch stealing;
- execute-inline overflow behavior;
- exact scheduler-owned completion accounting.

No scheduler-level need emerged for:

- a 16-byte TaskRef;
- execute target duplication in the queue element;
- public queue snapshots;
- allocator ownership inside TaskRef;
- TaskScope/cancellation/result fields in the universal hot header.

## Representation conclusion from P05

The selected hot-path form remains:

```text
TaskRef
    8-byte non-owning shared(TaskHeader)*

TaskHeader
    8-byte execute target
    initialized before publication
    read through safe shared atomic load

concrete task record
    TaskHeader first
    payload-specific fields after it
```

The type-specific downcast remains confined to the generated execution thunk.

## Remaining architecture gate

The qualification plan explicitly requires local native-x86_64 scheduler
measurement on the project XPS before R0.2 closes.

Hosted x86_64 CI proves compiler/runtime correctness and provides useful
relative evidence, but does not replace that local performance baseline.

Native AArch64 coverage is complete.

## Next gate

P06 — ownership/representation decision, after the local XPS confirmation is
recorded.


## Local XPS qualification

Local native-x86_64 qualification was executed on:

- Intel Core i7-9750H;
- 6 physical cores / 12 hardware threads;
- Linux x86_64;
- LDC 1.41.0;
- D frontend 2.111.0;
- LLVM 19.1.7;
- DUB 1.40.0.

Commit:

```text
a0e52ec0243fb25f26bf53b86013cdf88e8e2764
```

All three P05 probes passed.

### P05a XPS medians

```text
work0:
  single 1w   7.154
  batch  1w   7.213
  single 2w   8.190
  batch  2w   9.639
  single 4w  12.280
  batch  4w  24.055

work16:
  single 1w  35.133
  batch  1w  34.590
  single 2w  36.597
  batch  2w  32.225
  single 4w  40.613
  batch  4w  30.709

work64:
  single 1w 156.435
  batch  1w 156.309
  single 2w 138.728
  batch  2w 104.057
  single 4w 117.855
  batch  4w  58.744
```

The useful-work cases remain in the same performance class as the retained R0.1
flat qualification. Tiny work remains dominated by scheduling/coordination
cost and is not used as a standalone representation acceptance metric.

### P05b XPS medians

```text
single 1w 53.258 ns/task
batch  1w 46.748

single 2w 49.881
batch  2w 49.586

single 4w 51.161
batch  4w 51.402
```

This is materially slower than the retained R0.1 packed-value recursive
baseline.

The difference is intentionally not hidden: R0.1 stores synthetic task id and
depth directly inside the 8-byte queue value and calls the work kernel
directly, while R0.2 uses a real non-owning pointer to a TaskRecord, loads
record metadata, and dispatches through the record execute target.

The two forms therefore do not have equivalent task-representation semantics.

The recursive result is retained as the measurable cost of moving from a
synthetic value-handle lower bound to a general task-record representation.

### P05c XPS medians

```text
single 42.397 ns/task
batch  42.085 ns/task
```

The irregular TaskRef workload is faster than the earlier R0.1 XPS irregular
value-handle result and shows no representation-level regression in that
workload.

## P05d claimed-record diagnostic

A focused diagnostic tested whether the recursive gap was primarily caused by
safe shared atomic metadata loads.

The diagnostic replaced the repeated shared atomic metadata reads with a
single narrow trusted conversion to an execution-time unshared record view.

Result:

- DMD showed small workload-dependent changes;
- LDC/x86_64 was generally worse;
- native AArch64 was effectively unchanged.

Balanced native AArch64 ratios, claimed-record versus the selected
shared/atomic path:

```text
1 worker:
  single 0.9866x
  batch  0.9875x

2 workers:
  single 1.0042x
  batch  1.0141x

4 workers:
  single 1.0113x
  batch  1.0025x
```

Conclusion:

The recursive difference is not primarily caused by the safe atomic metadata
load shape.

The claimed-record shortcut is rejected as a production optimization because
it weakens the ordinary safety model without providing a consistent LDC
performance benefit.

## Final P05 interpretation

The scheduler-neighborhood evidence supports the selected 8-byte pointer-only
TaskRef as the best general-purpose representation among the qualified
candidates.

It is not free relative to a synthetic packed value handle for the smallest
recursive work. That lower bound is retained as useful evidence, but it cannot
represent an open-world general task system with independently stored payload,
lifetime and execute metadata.

No alternative qualified representation provides the same generality and
lifetime model with a better overall scheduler result.
