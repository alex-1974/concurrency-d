module app;

import std.stdio :
    writefln,
    writeln;

enum ulong halfRange =
    1UL << 63;

enum ulong capacity =
    256;

static assert(
    capacity < halfRange);

private ulong markBusy(
    ulong top)
    @nogc nothrow
{
    /*
     * Unsigned arithmetic is intentionally modulo 2^64.
     */
    return top + halfRange;
}

private ulong unmarkBusy(
    ulong state)
    @nogc nothrow
{
    return state + halfRange;
}

private ulong distance(
    ulong bottom,
    ulong topState)
    @nogc nothrow
{
    return bottom - topState;
}

private bool isPublishedBusyDistance(
    ulong d)
    @nogc nothrow
{
    /*
     * With an actual bottom value:
     *
     *     busy distance = 2^63 + occupancy
     *
     * and occupancy is bounded by capacity.
     */
    return
        d >= halfRange &&
        d <= halfRange + capacity;
}

private bool isOwnerBusyDistance(
    ulong d)
    @nogc nothrow
{
    /*
     * Owner has already speculatively decremented bottom.
     *
     * For every non-empty valid queue:
     *
     *     busy distance =
     *         2^63 + occupancy - 1
     *
     * Empty is the special value 2^63 - 1 and need not be treated as a
     * busy retry because the owner has no item to commit.
     */
    return
        d >= halfRange &&
        d < halfRange + capacity;
}

private void checkTop(
    ulong top)
{
    const marked =
        markBusy(top);

    if (unmarkBusy(marked) != top)
        throw new Exception(
            "busy transform is not involutive");

    /*
     * Check every legal occupancy for this small research capacity.
     */
    foreach (
        occupancy;
        0UL .. capacity + 1)
    {
        const bottom =
            top + occupancy;

        const idleDistance =
            distance(
                bottom,
                top);

        if (idleDistance != occupancy)
            throw new Exception(
                "idle distance mismatch");

        if (
            isPublishedBusyDistance(
                idleDistance))
        {
            throw new Exception(
                "valid idle state classified busy");
        }

        const busyDistance =
            distance(
                bottom,
                marked);

        const expectedBusyDistance =
            halfRange +
            occupancy;

        if (
            busyDistance !=
            expectedBusyDistance)
        {
            throw new Exception(
                "published busy distance mismatch");
        }

        if (
            !isPublishedBusyDistance(
                busyDistance))
        {
            throw new Exception(
                "busy state not recognized");
        }

        /*
         * tryPush must be able to recover the original full-width top
         * while a batch owns the marked state.
         */
        const recoveredTop =
            unmarkBusy(marked);

        const recoveredOccupancy =
            distance(
                bottom,
                recoveredTop);

        if (
            recoveredTop != top ||
            recoveredOccupancy != occupancy)
        {
            throw new Exception(
                "busy decode mismatch");
        }

        /*
         * Owner pop has already decremented bottom before observing top.
         */
        const ownerBottom =
            bottom - 1;

        const ownerDistanceIdle =
            distance(
                ownerBottom,
                top);

        const ownerDistanceBusy =
            distance(
                ownerBottom,
                marked);

        if (occupancy == 0)
        {
            /*
             * Normal empty Chase-Lev underflow.
             */
            if (
                ownerDistanceIdle !=
                ulong.max)
            {
                throw new Exception(
                    "empty owner idle distance mismatch");
            }

            /*
             * Empty + busy is deliberately outside the owner busy range.
             * Returning empty is conservative and correct.
             */
            if (
                ownerDistanceBusy !=
                halfRange - 1)
            {
                throw new Exception(
                    "empty owner busy distance mismatch");
            }

            if (
                isOwnerBusyDistance(
                    ownerDistanceBusy))
            {
                throw new Exception(
                    "empty busy state classified as owner retry");
            }
        }
        else
        {
            const expectedOwnerBusy =
                halfRange +
                occupancy -
                1;

            if (
                ownerDistanceBusy !=
                expectedOwnerBusy)
            {
                throw new Exception(
                    "owner busy distance mismatch");
            }

            if (
                !isOwnerBusyDistance(
                    ownerDistanceBusy))
            {
                throw new Exception(
                    "owner failed to recognize busy state");
            }
        }
    }
}

void main()
{
    immutable ulong[] anchors =
    [
        0UL,
        1UL,
        2UL,

        halfRange - 2,
        halfRange - 1,
        halfRange,
        halfRange + 1,
        halfRange + 2,

        ulong.max - 2,
        ulong.max - 1,
        ulong.max
    ];

    foreach (top; anchors)
    {
        checkTop(top);

        writefln(
            "top=%016x marked=%016x PASS",
            top,
            markBusy(top));
    }

    /*
     * Explicit boundary examples.
     */
    {
        const top =
            ulong.max - 3;

        const occupancy =
            8UL;

        const bottom =
            top + occupancy;

        const marked =
            markBusy(top);

        writefln(
            "wrap top=%016x bottom=%016x marked=%016x idleDistance=%s busyDistance=%s",
            top,
            bottom,
            marked,
            distance(bottom, top),
            distance(bottom, marked));

        if (
            distance(
                bottom,
                top) !=
            occupancy)
        {
            throw new Exception(
                "explicit wrap idle mismatch");
        }

        if (
            distance(
                bottom,
                marked) !=
            halfRange + occupancy)
        {
            throw new Exception(
                "explicit wrap busy mismatch");
        }
    }

    /*
     * Marking twice must recover the exact original raw 64-bit top for
     * every tested boundary state.
     */
    foreach (top; anchors)
    {
        if (
            markBusy(
                markBusy(top)) !=
            top)
        {
            throw new Exception(
                "double mark did not restore top");
        }
    }

    writeln(
        "R0.1 P08g0 PASS: full 64-bit top survives distance-marker encoding");
}
