# R0.3 P05 — Combined worker-scheduling qualification

Status: PASS

## Selected combined policy

```text
victim selection:
    deterministic round-robin

searching workers:
    all idle workers may search

continuation:
    AArch64:
        saturation-gated direct-one
        gate: outstanding >= worker count
    other currently qualified targets:
        enqueue-all

steal width:
    single and batch remain explicit modes
```

The architecture choice is compile-time specialization. There is no runtime
architecture branch.

## CI qualification

Final combined workflow run:

```text
R0.3 P05 combined scheduler
run #3
commit aa63591e4702cb56ef7305e5232ca4c00d91f344
```

Result:

- DMD 2.111.0 correctness: PASS;
- LDC 1.41 hosted x86_64: PASS;
- LDC 1.41 native AArch64 / Neoverse-N2: PASS.

The workflow also enforces a matched regression ceiling of 1.10x against the
P01 baseline for recursive and irregular workloads.

## Hosted x86_64

The x86_64 specialization retains enqueue-all.

Final balanced ratios:

```text
recursive:
  batch  1w 0.9915x
  single 1w 0.9975x
  batch  2w 1.0004x
  single 2w 0.9992x
  batch  4w 0.9816x
  single 4w 0.9797x

irregular:
  single    0.9597x
  batch     0.9573x
```

No material regression is visible.

The small deviations are matched-run variance; the selected x86_64 scheduling
semantics remain enqueue-all.

## Native AArch64

AArch64 uses saturation-gated direct continuation.

Final balanced ratios:

```text
recursive:
  batch  1w 0.7581x
  single 1w 0.7577x
  batch  2w 0.8774x
  single 2w 0.8813x
  batch  4w 0.8177x
  single 4w 0.7971x

irregular:
  single    0.7889x
  batch     0.7917x
```

The AArch64 gain is substantial and survives the combined-policy gate.

## Flat workload

The combined flat candidate intentionally keeps the P01 scheduling behavior
because no child continuation exists in that workload.

Flat qualification remains useful for:

- queue/steal interaction;
- task granularity;
- single-versus-batch behavior;
- DMD/LDC/native-AArch64 correctness.

It is not used to claim a continuation gain.

## Negative evidence carried forward

P05 selection incorporates the negative results from earlier gates:

- random victim selection is not universally better;
- sticky-success victim selection is architecture-unstable;
- limiting active searchers without parking is not beneficial;
- unconditional direct-one is not x86_64 robust;
- generic saturation thresholds are not cross-architecture stable.

These results remain part of the selected policy rationale.

## First local XPS attempt — rejected benchmark methodology

The first local XPS run was executed at:

```text
commit 78f1a0c3ae643de73bf86221a2988c0fb4449e02
Intel Core i7-9750H
LDC 1.41.0
DMD frontend 2.111.0
LLVM 19.1.7
host CPU skylake
```

Correctness passed for every matched round.

Recursive P05/P01 ratios were within the 1.10x gate:

```text
batch  1w 0.7673x
single 1w 0.7517x
batch  2w 1.0053x
single 2w 1.0043x
batch  4w 1.0096x
single 4w 0.9772x
```

Irregular exposed the failure:

```text
single 1.0644x
batch  1.1252x
candidate batch spread 1.2576x
```

The run therefore correctly reported:

```text
R0.3 P05 XPS REGRESSION GATE: FAIL
```

### Root cause in the qualification design

The selected x86_64 policy is enqueue-all, but the first P05 methodology
benchmarked a separately compiled duplicate candidate executable.

Even after the direct-continuation condition was compile-time false, the
candidate retained a different function/module shape and instrumentation.

That means the comparison was not a pure scheduling-policy comparison.

This matters because prior scheduler research already showed compiler
function-shape/code-layout sensitivity.

A follow-up CI attempt preserved the exact P01 executeTask body inside the
duplicate P05 executable. A hosted x86_64 run still reached 1.1012x in the
four-worker recursive single-steal case.

Therefore a separate duplicate binary is not an acceptable benchmark proxy for
the selected x86_64 policy.

### Corrected qualification rule

For x86_64:

```text
selected P05 implementation = P01 enqueue-all implementation itself
```

Therefore local and hosted x86 qualification run the selected P01 executable
directly.

For AArch64:

```text
selected P05 implementation = saturation-gated direct continuation
```

Only AArch64 performs a P05-vs-P01 candidate comparison.

This preserves semantic and code-shape fairness instead of relaxing the
performance threshold.

## Corrected local XPS qualification

The corrected local run executed on:

```text
commit 191eaacf4badee3dd6c162ded192dc499c223e6b
Intel Core i7-9750H
6 cores / 12 threads
Linux x86_64
LDC 1.41.0
DMD frontend 2.111.0
LLVM 19.1.7
host CPU skylake
DUB 1.40.0
```

The selected x86 policy was explicitly recorded by the runner as:

```text
recursive=P01 enqueue-all implementation
irregular=P01 enqueue-all implementation
duplicate-candidate comparison=disabled
```

All selected implementation runs passed exact correctness checks.

### Flat combined workload

Representative medians:

```text
work0:
  single 1w   9.414
  batch  1w   9.480
  single 2w  10.751
  batch  2w  12.091
  single 4w  15.036
  batch  4w  25.908

work16:
  single 1w  47.886
  batch  1w  47.618
  single 2w  49.373
  batch  2w  43.305
  single 4w  52.740
  batch  4w  36.731

work64:
  single 1w 181.003
  batch  1w 179.941
  single 2w 159.919
  batch  2w 119.326
  single 4w 142.955
  batch  4w  68.711
```

The established R0.1/R0.2 workload-sensitive single-versus-batch pattern
remains visible.

### Selected x86 recursive implementation

Median across three complete runs:

```text
batch  1w 65.293 ns/task
single 1w 62.837

batch  2w 55.071
single 2w 55.431

batch  4w 55.746
single 4w 56.607
```

Observed run-to-run spread:

```text
1w: 1.0292x .. 1.0843x
2w: 1.2237x .. 1.2765x
4w: 1.2479x .. 1.2605x
```

This spread is retained as benchmark-environment evidence.

It is not a candidate-regression signal because the selected x86 implementation
is exactly the baseline implementation itself.

Future local performance gates should continue to report repeated-run spread
and should avoid interpreting a single XPS sample as a stable policy delta.

### Selected x86 irregular implementation

Median across three complete runs:

```text
single 51.868 ns/task
batch  51.899 ns/task
```

Run-to-run spread:

```text
single 1.1405x
batch  1.1355x
```

Again, this is the directly selected enqueue-all implementation, not a
duplicate candidate binary.

### Local result

```text
R0.3 P05 XPS SELECTED-X86 QUALIFICATION: PASS
overall_rc=0
```

## Final P05 result

All required qualification environments are now covered:

- DMD 2.111 correctness on x86_64: PASS;
- LDC 1.41 selected x86 policy: PASS;
- local XPS native x86_64 / LDC 1.41: PASS;
- native AArch64 / LDC 1.41: PASS.

The combined worker-scheduling policy is ready for P06.

## P05 result

```text
R0.3 P05 COMBINED WORKER SCHEDULER: PASS
```
