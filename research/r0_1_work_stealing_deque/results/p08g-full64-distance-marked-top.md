# R0.1 P08g — Full-64 Distance-Marked Top

## Status

Preferred R0.1 research candidate after P08g2d.

This is not yet a production/public API decision.

The candidate preserves the complete 64-bit modular counter domain while
retaining a 64-bit atomic top state.

## Motivation

P08e demonstrated that a marked-top batch reservation can provide:

- near-baseline owner performance;
- protection against owner/batch overlap;
- strong batch-steal throughput.

Its research encoding consumed one bit of the top state:

    bits 63..1 = 63-bit counter
    bit 0      = busy

P08g investigates whether the full 64-bit counter domain can be retained
without introducing a separate atomic marker or requiring a wider CAS.

## P08g0 — Distance-marker algebra

The Full64 candidate uses:

    H = 2^63

Idle:

    rawTop = logicalTop

Busy:

    rawTop = logicalTop + H  (mod 2^64)

For a bounded deque with:

    capacity < 2^63

valid idle occupancy occupies:

    bottom - rawTop in [0, capacity]

while busy occupancy occupies:

    bottom - rawTop in [H, H + capacity]

These intervals are disjoint.

Adding H twice modulo 2^64 recovers the exact original top.

P08g0 qualified this algebra across boundary values including:

    0
    2^63 - 1
    2^63
    ulong.max
    ulong.max -> 0 wrap

under:

- DMD 2.111.0;
- LDC 1.41.0;
- LDC with `-preview=nosharedaccess`.

Result:

    PASS

## P08g1 — Concurrent correctness and full wrap

The Full64 candidate was inserted into the P08e forced-overlap and
multi-thief accounting harness.

Forced overlap exercised the owner busy-retry path.

Observed invariant:

    batch = 1,2,3,4
    owner = 8
    busyRetries > 0

Across 500 rounds with capacity 256, four thieves and batch width 8:

    submitted = 128000
    missing = 0
    duplicateValues = 0
    duplicateRecords = 0
    outOfRange = 0
    pushFailures = 0
    nonEmptyAfterDrain = 0
    invalidEmptyState = 0
    leakedBusy = 0

Unlike P08e, every round crosses the full:

    ulong.max -> 0

counter wrap.

DMD, LDC and LDC `-preview=nosharedaccess` all passed.

## P08g2 — Initial performance

The first Full64 implementation retained an SC barrier between:

    load top
    load bottom used for distance classification

and the existing required SC barrier after the successful busy CAS.

Concurrent drain measured approximately:

    29.0 ns/item

This was materially slower than P08e.

Owner-only performance remained near baseline:

    pop-many ~6.16 ns/op
    push-pop ~14.74 ns/op

Therefore the regression was isolated primarily to the thief batch path.

## P08g2c — RC11 state-classification qualification

The distance encoding cannot identify busy from top alone.

A concern was that a thief could:

1. observe a busy top;
2. observe a sufficiently old bottom;
3. classify the busy state as valid idle;
4. CAS the busy state back into the logical top domain.

An initial model was invalid because thread joins introduced a
happens-before chain that prevented the stale observation.

The corrected GenMC v0.19.0 RC11 model produced:

    acquire top model: SAFE
    relaxed control:   BUG FOUND

In the negative control GenMC found exactly the feared execution:

    Batch A:
        observes current bottom
        CAS top idle -> busy

    Batch B:
        relaxed-load top == busy
        acquire-load historical bottom
        CAS busy -> apparent idle

With Batch B's top load changed to acquire, this execution is excluded.

Therefore the acquire observation of another batch's busy publication is a
required part of the Full64 classification protocol.

## P08g2d — Remove redundant pre-CAS SC barrier

Based on the RC11 result, the SC barrier between the initial acquire top load
and the pre-CAS acquire bottom load was removed.

The post-CAS SC barrier remains unchanged because it belongs to the already
qualified owner-versus-batch ordering protocol.

Correctness after the change remained PASS under:

- LDC;
- DMD;
- LDC `-preview=nosharedaccess`;
- forced owner/batch overlap;
- 500-round full-width wrap stress.

Concurrent drain improved from approximately:

    29.009 ns/item

to:

    17.008 ns/item

in the first optimized measurement.

## P08g2d — Direct P08e versus Full64 comparison

Four alternating paired runs were performed using the same LDC build,
benchmark workload and host.

Per-run marked-top medians:

    P08e:
        18.275
        13.993
        18.079
        19.707 ns/item

    Full64:
        16.977
        17.740
        19.224
        17.422 ns/item

Median-of-runs:

    P08e    = 18.177 ns/item
    Full64  = 17.581 ns/item

Raw Full64 delta:

    -3.28 %

The benchmark is variable, so the more useful comparison normalizes each
marked-top result against the same run's steal-one baseline.

Normalized median:

    P08e    = 0.2374
    Full64  = 0.2379

Normalized Full64 delta:

    +0.21 %

This is performance parity for the purpose of architecture selection.

## Current architectural comparison

### P08e

    counter domain: 63 bit
    marker:         explicit encoded bit
    atomic width:   64 bit
    owner path:     near baseline
    batch path:     qualified
    wrap:           63-bit modular

### P08g Full64

    counter domain: full 64 bit
    marker:         impossible bounded-distance state
    atomic width:   64 bit
    owner path:     near baseline
    batch path:     performance parity with P08e
    wrap:           full ulong modular
    stale-state:    RC11 positive + negative-control qualification

## Current conclusion

P08g Full64 is the preferred R0.1 research candidate.

It improves on P08e by preserving the complete 64-bit counter domain without:

- widening the atomic top state;
- adding a second coordination atomic;
- introducing an owner-side gate;
- materially reducing measured performance.

This remains a research conclusion rather than a production contract.

Further qualification should retain the same standards already applied to
P08e/P08f, especially code-generation inspection, weak-memory reasoning and
scheduler-level workload validation.
