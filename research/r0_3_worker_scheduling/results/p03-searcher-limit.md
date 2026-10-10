# R0.3 P03 — Concurrent searching-worker limit

Status: PASS

## Goal

Determine whether reducing the number of idle workers that concurrently search
for stealable work improves scheduler-neighborhood performance.

Victim selection is fixed at the P02 decision:

```text
deterministic round-robin
```

Policies:

- `all` — every idle worker may search;
- `one` — at most one active searching worker;
- `bounded` — one searcher for two workers, two searchers for four workers.

Workers denied a search permit only yield. No parking primitive is introduced
in R0.3.

## Qualification

Result:

- DMD 2.111.0: PASS;
- LDC 1.41.0 hosted x86_64: PASS;
- native AArch64 / LDC 1.41 / Neoverse-N2: PASS.

All exact task/accounting invariants pass.

## Main finding

Searcher limiting substantially reduces active failed-steal traffic, but does
not reliably improve throughput.

The permit-miss count shows that the limits are active; the lack of a
consistent runtime win is therefore meaningful rather than an inactive-policy
artifact.

## Hosted LDC x86_64

Four-worker flat examples:

```text
work16 / batch:
  all      32.936 ns/task
  one      41.206
  bounded  36.990

work64 / batch:
  all      73.565
  one     101.230
  bounded  78.075
```

The one-searcher policy can reduce failed steals, but delays discovery and
redistribution enough to lose throughput.

Irregular workload:

```text
single:
  all      45.655
  one      45.657
  bounded  45.567

batch:
  all      45.690
  one      45.662
  bounded  45.624
```

The policies are effectively tied despite large differences in failed-steal
traffic.

## Native AArch64

The flat workload makes the rejection clearer.

Four-worker work64:

```text
single:
  all      143.106 ns/task
  one      197.618
  bounded  271.039

batch:
  all      133.368
  one      165.400
  bounded  196.526
```

Limiting searchers is therefore not architecture-robust as a spin/yield-only
policy.

Recursive and irregular workloads again show much smaller differences.

Native AArch64 irregular:

```text
single:
  all      204.382
  one      204.742
  bounded  204.913

batch:
  all      204.489
  one      204.886
  bounded  205.396
```

## Interpretation

The number of failed steals is not sufficient as an optimization objective.

A worker prevented from searching still consumes scheduling latency before
useful work is discovered.

Without an actual parking/wake protocol, limiting active searchers can trade
atomic/queue contention for slower work discovery.

That trade is unfavorable in important flat workloads, especially on ARM64.

## Decision

Carry forward into R0.3 P04/P05:

```text
searching-worker rule = all idle workers may search
```

This is not a final parking policy.

R0.4 must revisit active-searcher limits together with a real park/wake
mechanism, where denied search can avoid consuming CPU rather than repeatedly
yielding.

## Rejected for R0.3

- one active searcher;
- bounded two-searcher policy for four workers.

Both remain useful R0.4 inputs, but neither is selected as a pure scheduling
optimization.

## Next gate

P04 — continuation/direct-execution fast path.

Victim selection remains round-robin and all idle workers remain eligible to
search.
