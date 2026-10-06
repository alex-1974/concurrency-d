module app;

import concurrency.research.bounded_wsq :
    BoundedWorkStealingDeque;

import std.stdio : writefln, writeln;

alias Queue = BoundedWorkStealingDeque!(size_t, 3);

private void testPhysicalRingWraparound()
{
    Queue q;

    enum size_t rounds = 100_000;

    foreach (round; 0 .. rounds)
    {
        const base = round * Queue.capacity;

        foreach (i; 0 .. Queue.capacity)
            assert(q.tryPush(base + i + 1));

        /*
         * Alternate which end consumes the complete logical sequence.
         * This advances top/bottom through many physical slot wraps.
         */
        if ((round & 1) == 0)
        {
            foreach (i; 0 .. Queue.capacity)
            {
                const r = q.steal();

                assert(r.found);
                assert(r.value == base + i + 1);
            }
        }
        else
        {
            foreach_reverse (i; 0 .. Queue.capacity)
            {
                const r = q.pop();

                assert(r.found);
                assert(r.value == base + i + 1);
            }
        }

        assert(q.emptySnapshot());
    }

    writefln(
        "physicalRounds=%s physicalOperations=%s",
        rounds,
        rounds * Queue.capacity);
}

private void testLargeOffsetWithoutBoundary(long base)
{
    Queue q;

    q.researchSetEmptyIndex(base);

    assert(q.emptySnapshot());
    assert(q.researchTopSnapshot() == base);
    assert(q.researchBottomSnapshot() == base);

    assert(q.tryPush(11));
    assert(q.tryPush(22));
    assert(q.tryPush(33));
    assert(q.tryPush(44));

    auto oldest = q.steal();
    auto newest = q.pop();
    auto nextOldest = q.steal();
    auto last = q.pop();

    assert(oldest.found && oldest.value == 11);
    assert(newest.found && newest.value == 44);
    assert(nextOldest.found && nextOldest.value == 22);
    assert(last.found && last.value == 33);

    assert(q.emptySnapshot());
}

private bool characterizeSignedBoundary()
{
    Queue q;

    /*
     * Four pushes cross long.max -> long.min.
     *
     * D defines signed integral overflow as wraparound. The question here is
     * whether the deque's ordering comparisons remain meaningful across that
     * boundary.
     */
    q.researchSetEmptyIndex(long.max - 2);

    bool allPushed = true;

    foreach (value; 1 .. 5)
        allPushed = q.tryPush(value) && allPushed;

    size_t[4] returnedValues;
    size_t returned;

    /*
     * Try both ends. This experiment does not assume either result in advance.
     */
    foreach (_; 0 .. 4)
    {
        auto r = q.steal();

        if (r.found && returned < returnedValues.length)
            returnedValues[returned++] = r.value;
    }

    foreach (_; 0 .. 4)
    {
        auto r = q.pop();

        if (r.found && returned < returnedValues.length)
            returnedValues[returned++] = r.value;
    }

    bool seenAll = allPushed && returned == 4;

    if (seenAll)
    {
        bool[5] seen;

        foreach (i; 0 .. returned)
        {
            const value = returnedValues[i];

            if (value < 1 || value > 4 || seen[value])
            {
                seenAll = false;
                break;
            }

            seen[value] = true;
        }

        foreach (value; 1 .. 5)
        {
            if (!seen[value])
                seenAll = false;
        }
    }

    writefln(
        "signedBoundary allPushed=%s returned=%s "
        ~ "top=%s bottom=%s sizeSnapshot=%s preserved=%s",
        allPushed,
        returned,
        q.researchTopSnapshot(),
        q.researchBottomSnapshot(),
        q.sizeSnapshot(),
        seenAll);

    return seenAll;
}

void main()
{
    testPhysicalRingWraparound();

    /*
     * Large positive and negative offsets are tested separately while staying
     * comfortably inside one signed-ordering region.
     */
    testLargeOffsetWithoutBoundary(long.max - 4096);
    testLargeOffsetWithoutBoundary(long.min + 4096);

    writeln("largeOffsetWithoutBoundary=PASS");

    const signedBoundaryPreserved =
        characterizeSignedBoundary();

    writefln(
        "signedBoundaryPreserved=%s",
        signedBoundaryPreserved);

    writeln(
        "R0.1 P04 PASS: physical wraparound verified; "
        ~ "signed counter boundary characterized");
}
