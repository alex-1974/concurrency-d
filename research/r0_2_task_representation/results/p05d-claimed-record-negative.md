# R0.2 P05d — Claimed-record execution diagnostic

Status: NEGATIVE EVIDENCE

## Question

Is the recursive P05b performance gap primarily caused by repeatedly reading
immutable-after-publication TaskRecord metadata through shared atomic loads?

## Variant

The diagnostic retained:

- the same 8-byte TaskRef;
- the same TaskRecord layout;
- the same containers-d WorkStealingDeque;
- the same recursive graph;
- the same work function;
- the same ownership/lifetime model.

Only the execution read path changed.

The diagnostic used the existing narrow trusted TaskRef -> TaskRecord
conversion and then direct ordinary field loads for:

- id;
- depth;
- execute target.

No queue or scheduler semantics changed.

## Results

### DMD 2.111 / hosted x86_64

The claimed-record variant showed only small workload-dependent differences.

Representative four-worker values:

```text
selected shared/atomic:
  single 53.630 ns/task
  batch  51.895

claimed-record:
  single 49.285
  batch  49.361
```

This compiler-specific improvement is not sufficient to select the weaker
execution boundary.

### LDC 1.41 / hosted x86_64

The claimed-record variant was generally slower.

Representative one-worker values:

```text
selected shared/atomic:
  single 31.452 ns/task
  batch  31.270

claimed-record:
  single 36.250
  batch  36.066
```

Four-worker values were approximately equal to slightly worse.

### Native AArch64 / LDC 1.41 / Neoverse-N2

Balanced comparison:

```text
batch  workers=1 ratio=0.9875x
single workers=1 ratio=0.9866x

batch  workers=2 ratio=1.0141x
single workers=2 ratio=1.0042x

batch  workers=4 ratio=1.0025x
single workers=4 ratio=1.0113x
```

The difference is effectively noise-level and not a meaningful optimization.

## Decision

Reject the claimed-record shortcut as the R0.2 production direction.

The evidence does not justify weakening the ordinary safe shared metadata
access model.

The recursive TaskRef cost is therefore attributed primarily to the real
pointer-based task-record representation and its dependent metadata/payload
access, not to the atomic-load syntax itself.

The selected R0.2 contract remains:

```text
TaskRef
    8-byte non-owning shared(TaskHeader)*

TaskHeader
    8-byte execute target
    initialized before publication
    loaded through safe shared access

type-specific execution thunk
    narrow generated type-erasure boundary
```
