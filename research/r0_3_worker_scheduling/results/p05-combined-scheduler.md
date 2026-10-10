# R0.3 P05 — Combined worker-scheduling qualification

Status: CI REQUALIFYING — LOCAL XPS RERUN PENDING

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

## Remaining gate

R0.3 requires local native-x86_64 qualification on the project XPS.

The corrected local gate must:

- use LDC 1.41.0;
- record platform/toolchain identity;
- run the combined flat workload;
- run the selected x86 recursive implementation, which is P01 enqueue-all;
- run the selected x86 irregular implementation, which is P01 enqueue-all;
- repeat both selected workloads three times;
- preserve exact correctness checks;
- report run-to-run spread.

No duplicate x86 candidate binary is used for performance comparison.

P05 becomes final PASS only after that corrected evidence is recorded.
