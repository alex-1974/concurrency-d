# P08g2c — Full64 distance-marker stale-bottom qualification

## Purpose

The full-64 distance-marker candidate represents batch busy by publishing:

    rawTop = logicalTop + 2^63  (mod 2^64)

Because busy cannot be decoded from rawTop alone, a thief classifies the state
using the modular distance between bottom and rawTop.

The critical question is whether a thief that observes another batch's busy
publication can subsequently observe a sufficiently old bottom value and
mistake busy for a valid idle state.

## Initial invalid harness

`stale_bottom_invalid_join_control.c` was the first attempt.

It joined the history-producing thread before starting the observing thief.

That introduced a happens-before chain that forced the later bottom read past
the current bottom publication.

GenMC therefore explored only the synchronized outcome.

This probe is retained as research evidence but is not a qualification test.

## Corrected positive probe

`stale_bottom_acquire.c` models:

1. Batch A observes the current valid bottom.
2. Batch A publishes the busy top with a seq_cst CAS.
3. Batch B observes that busy top with an acquire load.
4. Batch B then observes bottom.

GenMC v0.19.0 under RC11 reports the model SAFE.

## Negative control

`stale_bottom_relaxed_control.c` weakens only Batch B's top observation from
acquire to relaxed.

GenMC then finds the feared execution:

    Batch A:
        bottom = current
        CAS top idle -> busy

    Batch B:
        load top == busy          relaxed
        load historical bottom
        classify busy as idle
        CAS busy -> apparent idle

The negative control therefore establishes that the positive result is not
vacuous and that the acquire observation of the busy publication is essential
to the Full64 state-classification argument.
