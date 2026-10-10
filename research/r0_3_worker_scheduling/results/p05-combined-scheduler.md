# R0.3 P05 — Combined worker-scheduling qualification

Status: CI PASS — LOCAL XPS PENDING

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

## Remaining gate

R0.3 requires local native-x86_64 qualification on the project XPS.

The local gate must:

- use LDC 1.41.0;
- record platform/toolchain identity;
- run the combined flat workload;
- compare P01 versus P05 recursive in balanced repeated order;
- compare P01 versus P05 irregular in balanced repeated order;
- preserve exact correctness checks;
- reject a material >1.10x regression.

P05 becomes final PASS only after that evidence is recorded.
