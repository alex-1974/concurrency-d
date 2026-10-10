# R0.3 P02 — Victim-selection policy

Status: PASS

## Goal

Compare worker victim-selection order while holding constant:

- containers-d queue;
- R0.2 TaskRef/TaskHeader;
- task graphs;
- steal width;
- completion accounting;
- worker affinity;
- compiler/build mode.

Policies:

1. deterministic round-robin;
2. deterministic per-worker pseudo-random;
3. sticky-success with three bounded retries before randomized fallback.

The probes also count victim switches.

## Qualification

Workflow:

```text
R0.3 P02 victim selection
run #1
```

Result:

- DMD 2.111.0: PASS;
- LDC 1.41.0 hosted x86_64: PASS;
- native AArch64 / LDC 1.41 / Neoverse-N2: PASS.

All policies preserve exact task/accounting semantics.

## Main finding

There is no universal throughput winner.

The most important result is negative:

```text
sticky-success is not architecture-robust
```

It can dramatically reduce victim switching and failed-steal traffic, yet that
does not reliably translate to lower task latency.

## Hosted LDC x86_64

Sticky-success can be attractive in some four-worker flat cases.

Examples:

```text
work16 / batch / 4 workers:
  round-robin     30.214 ns/task
  random          30.433
  sticky-success  26.209

work64 / single / 4 workers:
  round-robin     99.915
  random         125.377
  sticky-success  72.040

work64 / batch / 4 workers:
  round-robin     67.216
  random          69.450
  sticky-success  62.726
```

Sticky-success also cuts victim switching sharply in these cases.

However, this result does not survive architecture transfer.

## Native AArch64

On Neoverse-N2, sticky-success can materially regress the same flat policy
space.

Examples:

```text
work16 / single / 4 workers:
  round-robin    120.535 ns/task
  random          97.013
  sticky-success 182.551

work64 / single / 4 workers:
  round-robin    142.721
  random         150.187
  sticky-success 165.627

work64 / batch / 4 workers:
  round-robin    127.909
  random         139.153
  sticky-success 185.966
```

The sticky policy therefore fails the R0.3 requirement that a selected policy
must not buy a synthetic/local win through severe regressions elsewhere.

## Recursive workload

Victim choice has very little effect on recursive throughput because successful
stealing is sparse relative to owner-local execution.

Native AArch64 four-worker medians:

```text
single:
  round-robin    165.469 ns/task
  random         166.213
  sticky-success 165.686

batch:
  round-robin    165.962
  random         166.066
  sticky-success 165.836
```

The policies differ more in search behavior than in execution throughput.

## Irregular workload

Native AArch64:

```text
single:
  round-robin    203.755 ns/task
  random         203.339
  sticky-success 203.674

batch:
  round-robin    203.541
  random         203.596
  sticky-success 203.583
```

Again, throughput is effectively equal even though victim-switch counts differ
substantially.

Hosted x86_64 showed more variation, including an improvement for sticky batch,
but not enough to overcome the ARM64 flat regressions.

## Search-behavior finding

Reducing victim switches is not itself a sufficient optimization target.

Sticky-success often reduced switching by an order of magnitude, yet could be
slower.

Therefore future scheduler policy should treat:

- victim switching;
- failed steals;
- successful claims;

as diagnostic metrics, not direct optimization objectives.

The end metric remains semantically matched scheduler-neighborhood throughput.

## Decision

Select for the R0.3 baseline:

```text
victim selection = deterministic round-robin
```

Reasons:

- architecture-robust;
- simple and deterministic;
- no per-attempt PRNG cost;
- no sticky locality assumption;
- no severe regression across the qualified workloads;
- provides the cleanest basis for isolating P03 searching-worker limits.

Random victim selection remains a possible future specialization when worker
counts/topology become larger than the current R0.x qualification space.

Sticky-success is rejected as the generic R0.3 policy.

## Next gate

P03 — bounded concurrently searching workers.

Victim selection remains fixed at round-robin while only the searcher count is
varied.
