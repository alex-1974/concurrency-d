# P05 — Signed vs Modular Code Generation

## Scope

Compare the current signed Taskflow-style bounded WSQ candidate against the
modulo-2^64 unsigned candidate.

Operations:

- `tryPush`
- `pop`
- `steal`

The comparison is code-generation evidence only. It is not yet a runtime
performance result.

## Toolchains

- DMD 2.111.0
- LDC 1.41.0 / LLVM 19.1.7
- x86_64
- release optimization
- bounds checks disabled for the isolated codegen object

## Semantic control

Both candidates produced the same checksum:

    8256

under DMD and LDC.

## DMD method symbol sizes

| operation | signed | modular | delta |
|---|---:|---:|---:|
| push | 105 B | 105 B | 0 B |
| pop | 175 B | 185 B | +10 B |
| steal | 114 B | 129 B | +15 B |

DMD did not inline the queue methods into the push/pop probe wrappers in this
object. Relocations confirm that the wrappers call the corresponding template
method symbols directly.

Therefore the method symbols, not the wrapper sizes, are the relevant DMD
comparison.

## LDC method symbol sizes

| operation | signed | modular | delta |
|---|---:|---:|---:|
| push | 47 B | 46 B | -1 B |
| pop | 72 B | 84 B | +12 B |
| steal | 46 B | 61 B | +15 B |

## LDC instruction-shape observation

### Push

Both variants reduce to closely comparable load/subtract/capacity-test/store
sequences.

The modular implementation does not introduce a meaningful code-size penalty
for `tryPush`.

### Pop

The modular candidate computes the modulo distance after the speculative
bottom decrement and performs a bounded-capacity test before entering the
normal item / last-item paths.

This produces additional instructions relative to the signed-ordering
candidate.

### Steal

The signed candidate primarily tests the absolute ordering relation between
top and bottom.

The modular candidate computes:

    count = bottom - top

and rejects both:

    count == 0
    count > capacity

before entering the same item-load and CAS path.

This adds code on the steal path.

## Interpretation

Current codegen evidence:

    push:
        effectively equivalent

    pop:
        modular moderately larger

    steal:
        modular clearly larger

The modular candidate remains semantically stronger because it preserves the
counter contract across full unsigned wraparound.

Code size alone is insufficient to choose the production candidate.

The next gate is runtime microbenchmarking under the repository benchmark
discipline, with LDC as the primary optimized compiler.

Required initial workloads:

1. owner-local push
2. owner-local pop with more than one queued item
3. owner push/pop pair
4. empty steal
5. successful steal

No production promotion decision follows from P05 alone.
