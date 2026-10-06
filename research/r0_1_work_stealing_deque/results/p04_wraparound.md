# P04 — Ring and Counter Wraparound

## Candidate

Current bounded work-stealing deque using signed 64-bit monotonic
`top` and `bottom` counters.

The implementation follows the Taskflow-style bounded Chase-Lev shape.

## Toolchains

- DMD 2.111.0
- LDC 1.41.0 / LLVM 19.1.7
- x86_64
- normal builds
- `-preview=nosharedaccess` builds

## Physical ring wraparound

Probe:

- capacity: 8
- rounds: 100,000
- physical queue operations: 800,000
- alternating complete consumption from thief/top and owner/bottom

Result:

    PASS

Repeated reuse of the physical slots through mask arithmetic preserves the
logical sequence.

## Large logical offsets

The same deque semantics were tested after relocating the empty logical
counter state near:

- `long.max - 4096`
- `long.min + 4096`

without crossing the signed boundary.

Result:

    PASS

Large absolute signed counter values alone are therefore not the problem.

## Signed boundary crossing

The empty deque was positioned at:

    long.max - 2

Four pushes were then performed, forcing `bottom` through:

    long.max -> long.min

Observed on DMD and LDC:

    allPushed=true
    returned=0
    top=9223372036854775805
    bottom=-9223372036854775807
    sizeSnapshot=0
    preserved=false

The result is identical with `-preview=nosharedaccess`.

## Interpretation

D defines signed integer overflow as wraparound, but the current deque
algorithm relies on signed ordering relations such as:

    t < b
    t <= b
    b - t

Those relations no longer preserve the logical monotonic ordering when the
counter crosses from `long.max` to `long.min`.

Therefore the current candidate has a finite signed counter domain even though
physical slot indexing itself wraps correctly.

## Status

This result does not yet choose the production representation.

R0.1 must compare:

1. retaining the signed monotonic-counter model with an explicit finite-domain
   invariant; and
2. a modular/unsigned counter formulation that preserves deque semantics across
   the full machine-word wraparound.

The alternative must be evaluated for:

- correctness;
- memory-ordering compatibility;
- generated code;
- owner-local hot-path cost;
- steal-path cost;
- DMD/LDC behaviour.

No production API or containers-d contract is implied by P04 alone.
