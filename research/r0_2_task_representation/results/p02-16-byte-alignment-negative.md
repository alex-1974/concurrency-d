# R0.2 P02b/P02c — 16-byte queue transport alignment finding

Status: NEGATIVE EVIDENCE / CANDIDATE BLOCKED

## Context

P01 established that the following representation compiles as a
`containers-d 0.2.0` WorkStealingDeque element:

```d
struct PointerExecuteRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}
```

Layout on all qualified targets:

```text
sizeof  = 16
alignof = 8
```

P01 compile compatibility was therefore not sufficient to establish runtime
transport safety.

## P02b failure

P02b moved the real 16-byte representation through the production deque while
combining owner push/pop with task dispatch.

DMD 2.111 completed the probe.

LDC 1.41 failed during runtime transport:

- Linux x86_64: process signal corresponding to exit code -11 / SIGSEGV;
- native Linux AArch64: process signal corresponding to exit code -7 / SIGBUS.

The same probe's 8-byte paths did not establish an equivalent architecture
failure.

Relevant research run:

```text
workflow run #11
head e92687723c7462f947a2ae1d2dbc35c2a93708a4
```

## Alignment diagnostic

P02c compared the original representation with an explicitly aligned form:

```d
align(16)
struct AlignedPointerExecuteRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}
```

Observed layout:

```text
PointerExecuteRef:
    size       = 16
    align      = 8
    queueAlign = 8

AlignedPointerExecuteRef:
    size       = 16
    align      = 16
    queueAlign = 16
```

The aligned 16-byte form completed 640,000 repeated push/pop transfers plus
function-pointer use on:

- DMD 2.111 / x86_64: PASS;
- LDC 1.41 / x86_64: PASS;
- LDC 1.41 / native AArch64 Neoverse-N2: PASS.

This strongly supports insufficient alignment of the admitted 16-byte atomic
representation as the cause of the P02b LDC failures.

## containers-d implication

The current containers-d transport predicate checks whether shared atomic
load/store expressions compile and whether T has acceptable lifetime traits.

For this representation, compile-time acceptance does not by itself guarantee
that the containing deque provides the alignment required by optimized
16-byte atomic transport.

This is a consumer-discovered limitation in the current production-neighbourhood
contract.

R0.2 does not modify containers-d as part of this finding.

## R0.2 decision

The unaligned 16-byte PointerExecuteRef is blocked from further production
consideration under containers-d 0.2.0.

Even if a future containers-d version strengthens 16-byte alignment, the
candidate would still have to overcome the already measured queue-footprint
and transfer disadvantage relative to an 8-byte TaskRef.

Candidates continuing in the main R0.2 path:

1. 8-byte pointer-only with record-stored execute function;
2. 8-byte pointer-only with compact immutable record discriminator.

The failing P02b probe is retained as negative evidence rather than rewritten
into a passing test.
