# R0.3 P01 — Worker-scheduling baseline

Status: PASS

## Goal

Establish a scheduler-policy baseline on the selected R0.2 task representation
before changing victim selection, searcher limits or continuation policy.

The baseline intentionally reuses the qualified R0.2 scheduler-neighborhood
semantics:

- `containers-d 0.2.0` `WorkStealingDeque`;
- 8-byte pointer-only `TaskRef`;
- 8-byte `TaskHeader` execute target;
- fixed worker affinity where available;
- exact scheduler-owned accounting;
- no parking;
- no allocator/pool experiment.

## Qualification run

Workflow:

```text
R0.3 P01 scheduling baseline
run #1
commit 8b893ac6a32d64169c09f13a1e1170733348ba92
```

Result:

- DMD 2.111.0 / hosted x86_64: PASS;
- LDC 1.41.0 / hosted x86_64: PASS;
- LDC 1.41.0 / native AArch64 / ARM Neoverse-N2: PASS.

All flat, recursive and irregular exact-correctness checks passed.

## P01a — flat granularity

Configuration:

- 262,144 tasks;
- capacity 1024;
- batch size 8;
- work = 0 / 16 / 64;
- workers = 1 / 2 / 4;
- single and batch stealing.

Hosted LDC x86_64 medians:

```text
work0:
  single 1w   2.633
  batch  1w   2.636
  single 2w   3.367
  batch  2w   3.747
  single 4w   5.051
  batch  4w  11.794

work16:
  single 1w  30.078
  batch  1w  30.058
  single 2w  42.690
  batch  2w  35.268
  single 4w  44.323
  batch  4w  27.821

work64:
  single 1w 166.296
  batch  1w 166.293
  single 2w 155.222
  batch  2w 113.425
  single 4w 127.478
  batch  4w  62.080
```

Native AArch64 retains the expected workload sensitivity:

- tiny tasks are dominated by scheduling/steal coordination;
- batch stealing can regress the smallest cases;
- useful work can amortize batch transfer.

## P01b — recursive fork/join

Configuration:

- depth 18;
- 524,287 tasks;
- work=16;
- capacity 1024;
- batch size 8;
- workers = 1 / 2 / 4.

Hosted LDC x86_64:

```text
single 1w 35.517 ns/task
batch  1w 35.700

single 2w 27.565
batch  2w 27.619

single 4w 35.422
batch  4w 35.390
```

Native AArch64 / Neoverse-N2:

```text
single 1w  40.357 ns/task
batch  1w  40.319

single 2w 134.652
batch  2w 134.318

single 4w 192.207
batch  4w 193.740
```

The architecture-specific scaling difference remains evidence for later
scheduling-policy work and is not normalized away.

## P01c — irregular graph

Configuration:

- four workers;
- deterministic irregular graph;
- 218,643 tasks;
- capacity 1024;
- batch size 8;
- exact execution/spawn/checksum validation.

Hosted LDC x86_64:

```text
single 31.384 ns/task
batch  31.356 ns/task
```

Native AArch64 / Neoverse-N2:

```text
single 211.711 ns/task
batch  211.870 ns/task
```

## Baseline victim policy

The P01 worker loop uses deterministic round-robin victim traversal.

Each idle worker cycles through the other workers and attempts steal operations
until work is found or the scan completes.

This policy is the exact baseline for P02.

## Result

```text
R0.3 P01 WORKER-SCHEDULING BASELINE: PASS
```

P02 may now change only victim-selection order while preserving the queue,
TaskRef, task graphs, steal width and completion semantics.
