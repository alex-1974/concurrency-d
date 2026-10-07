# P15 — Native AArch64 Runtime Qualification

Status: pending native runtime

## Goal

Reduce the asymmetry between x86_64 runtime evidence and AArch64
code-generation-only evidence.

Cross-compilation is not considered equivalent to native runtime evidence.

## Required native AArch64 coverage

At minimum repeat:

1. core correctness;
2. last-item race;
3. multi-thief accounting;
4. marked-top batch overlap;
5. scheduler-like performance;
6. one end-to-end scheduler workload.

## Candidate reuse

Prefer reusing already-qualified probes rather than creating new algorithms.

Candidate probe families:

- correctness / last-item:
  existing P0x queue correctness probes;
- multi-thief:
  existing P08c-style contention/accounting probe;
- marked-top batch overlap:
  P08e/P13 scheduler overlap evidence;
- scheduler-like:
  P08h/P13-style harness;
- end-to-end:
  P14 workload family.

## Evidence requirements

Record:

- architecture;
- CPU model;
- operating system;
- kernel;
- DMD version;
- LDC version;
- LLVM version;
- worker affinity/topology;
- exact concurrency-d commit;
- exact Taskflow commit if used;
- all correctness results;
- performance samples and medians.

## Promotion rule

Native execution is preferred.

If no native AArch64 machine is available, record the limitation explicitly.
Cross-compilation/code-generation inspection alone does not close P15.
