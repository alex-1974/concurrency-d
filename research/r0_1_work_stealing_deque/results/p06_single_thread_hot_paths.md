# P06 — Signed vs Modular Single-Thread Hot Paths

## Scope

Compare the signed Taskflow-style bounded work-stealing deque against the
modulo-2^64 unsigned candidate on isolated single-thread hot paths.

This probe measures algorithmic local-operation cost only.

It does not yet measure:

- cross-core cache-line movement;
- owner/thief contention;
- multi-thief contention;
- worker scheduling;
- parking/wakeup;
- end-to-end task execution.

## Platform

CPU:

    Intel Core i7-9750H
    6 cores / 12 hardware threads
    x86_64

Primary performance compiler:

    LDC 1.41.0
    DMD frontend 2.111.0
    LLVM 19.1.7
    host CPU skylake

Correctness/comparison compiler:

    DMD 2.111.0

DUB:

    1.40.0

Queue capacity:

    262144

Primary LDC measurement:

    CPU affinity: CPU 2
    warmups: 6
    samples: 24

## Workloads

### push

Push a complete capacity worth of items into an empty queue.

Reset/setup is outside the timed region.

### pop-many

Start from a full queue and pop all but one item.

The final last-item CAS path is deliberately excluded.

### push-pop-pair

Maintain owner-local occupancy around two items.

One benchmark operation consists of one push followed by one ordinary pop.

### empty-steal

Repeatedly steal from an empty queue.

### successful-steal

Start from a full queue and steal all items.

Queue preparation is outside the timed region.

## LDC primary run

| workload | signed ns/op | modular ns/op | modular/signed |
|---|---:|---:|---:|
| push | 1.441 | 1.334 | 0.925x |
| pop-many | 17.359 | 16.981 | 0.978x |
| push-pop-pair | 24.586 | 25.573 | 1.040x |
| empty-steal | 16.241 | 16.272 | 1.002x |
| successful-steal | 15.719 | 16.227 | 1.032x |

## LDC repeat

| workload | signed ns/op | modular ns/op | modular/signed |
|---|---:|---:|---:|
| push | 1.396 | 1.294 | 0.927x |
| pop-many | 17.070 | 16.587 | 0.972x |
| push-pop-pair | 27.764 | 27.965 | 1.007x |
| empty-steal | 16.022 | 16.274 | 1.016x |
| successful-steal | 15.838 | 16.173 | 1.021x |

## DMD control run

The DMD release run completed successfully.

Results are retained as correctness/codegen context rather than the primary
performance decision because R0.1 designates LDC as the optimized performance
compiler.

## Interpretation

The P05 code-size increase of the modular candidate does not translate into a
general hot-path slowdown.

Observed under LDC:

    owner push:
        modular median faster in both runs

    ordinary owner pop:
        modular median slightly faster in both runs

    push/pop steady state:
        approximately equal; modular ranges from ~0.7% to ~4% slower

    empty steal:
        approximately equal; modular up to ~1.6% slower

    successful steal:
        modular ~2.1% to ~3.2% slower

The second push run has a comparatively wide distribution, especially for the
signed candidate, so the apparent push advantage must not yet be treated as a
stable optimization claim.

The robust conclusion is:

    modular counter semantics do not impose a broad local hot-path penalty.

The remaining consistent local cost is concentrated in the steal path.

## Decision status

The modular candidate remains preferred for further research because it:

- preserves correctness across full machine-word counter wrap;
- has competitive owner-local performance;
- pays only a small measured local steal penalty so far.

No production promotion decision is made by P06.

## Next gate

Compare materially equivalent workloads against the pinned Taskflow bounded
work-stealing queue reference.

After that, measure:

- one owner + one thief;
- one owner + N thieves;
- repeated contention;
- cache-line/layout effects.
