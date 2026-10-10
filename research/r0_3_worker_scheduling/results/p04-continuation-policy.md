# R0.3 P04 — Continuation/direct-execution policy

Status: PASS

## Goal

Determine whether a worker should execute one freshly spawned child directly
instead of always enqueueing every child.

The lower-level contract remains fixed:

- `containers-d 0.2.0` WorkStealingDeque;
- R0.2 8-byte TaskRef;
- deterministic round-robin victim selection;
- all idle workers may search;
- exact outstanding/completion accounting.

The hot-path continuation implementation is iterative. It does not recurse with
task depth.

## Candidates

### A — enqueue-all baseline

Every spawned child is published to the owner-local deque.

This is the P01 baseline.

### B — unconditional direct-one

For each spawning task:

- retain one child as the current worker's direct continuation;
- enqueue the siblings;
- execute the continuation through an iterative loop.

### C — saturation-gated direct-one

First preserve enough scheduler-visible work to cover the worker team.

After child accounting is published:

```text
if outstanding >= workerCount:
    retain one child as direct continuation
    enqueue siblings
else:
    enqueue all children
```

The irregular four-worker probe uses the equivalent fixed threshold.

## Correctness

All variants passed exact task, spawn and checksum accounting on:

- DMD 2.111.0;
- LDC 1.41.0 hosted x86_64;
- native AArch64 / LDC 1.41 / Neoverse-N2.

The direct hot path remains iterative and therefore does not introduce
task-depth-proportional stack growth.

Cold queue-overflow execution retains the already-qualified recursive inline
fallback.

## Unconditional direct-one result

### Hosted LDC x86_64

Balanced direct-one / enqueue-all ratios:

```text
recursive:
  batch  1w 0.9091x
  single 1w 0.9086x
  batch  2w 0.9369x
  single 2w 0.9380x
  batch  4w 1.3049x
  single 4w 1.3062x

irregular:
  single    1.0127x
  batch     1.0120x
```

The candidate improves one- and two-worker recursive execution but causes an
unacceptable ~30% regression at four workers.

The cause is scheduler-visible parallelism: direct-one keeps work local too
early, before enough sibling work has been exposed to the worker team.

### Native AArch64

Balanced ratios:

```text
recursive:
  batch  1w 0.7306x
  single 1w 0.7317x
  batch  2w 0.8090x
  single 2w 0.8199x
  batch  4w 0.7624x
  single 4w 0.7199x

irregular:
  single    0.9283x
  batch     0.9286x
```

Unconditional direct-one is strongly beneficial on the Neoverse-N2 runner.

The architecture disagreement means unconditional direct-one is rejected as
the generic R0.3 policy.

## Saturation-gated result

### Hosted LDC x86_64

Balanced saturation-gated / enqueue-all ratios:

```text
recursive:
  batch  1w 0.9587x
  single 1w 0.9368x
  batch  2w 0.9728x
  single 2w 0.9746x
  batch  4w 1.0126x
  single 4w 1.0111x

irregular:
  single    0.9347x
  batch     0.9403x
```

The gating removes the four-worker regression while retaining useful
one-/two-worker and irregular gains.

### Native AArch64

Balanced ratios:

```text
recursive:
  batch  1w 0.7586x
  single 1w 0.7583x
  batch  2w 0.8189x
  single 2w 0.8236x
  batch  4w 0.7602x
  single 4w 0.7711x

irregular:
  single    0.8876x
  batch     0.8892x
```

The large ARM64 benefit survives the saturation gate.

## Interpretation

The useful optimization is not simply "execute a child directly".

The robust rule is:

```text
preserve team parallelism first,
then keep a continuation local
```

This is a scheduler policy, not a queue property.

The threshold is deliberately expressed through already-accounted outstanding
work rather than queue snapshots, because concurrent queue size/empty
snapshots are stale by construction and not part of the production
containers-d API.

## Decision

Select for R0.3 P05:

```text
continuation policy:
    saturation-gated direct-one

gate:
    use direct continuation only when
    scheduler-visible outstanding work >= worker count

execution:
    iterative local continuation
    siblings published to local deque

overflow:
    retain P12 execute-inline fallback
```

Unconditional direct-one remains retained negative/architecture-specific
evidence.

## Combined policy entering P05

```text
victim selection:
    deterministic round-robin

searching workers:
    all idle workers may search

continuation:
    saturation-gated direct-one

steal width:
    single and batch remain explicit workload-dependent modes
```

No dynamic single/batch selector is introduced without separate evidence.

## Next gate

P05 — combined worker-scheduling qualification on DMD, LDC, native ARM64 and
the local project XPS.
