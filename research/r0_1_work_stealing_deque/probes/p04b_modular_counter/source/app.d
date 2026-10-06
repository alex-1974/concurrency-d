module app;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import std.stdio : writefln, writeln;

alias Queue = ModularBoundedWorkStealingDeque!(size_t, 3);

private void testOrdinarySemantics()
{
    Queue q;

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

    assert(!q.pop().found);
    assert(!q.steal().found);
    assert(q.emptySnapshot());
}

private void testCapacity()
{
    Queue q;

    foreach (i; 0 .. Queue.capacity)
        assert(q.tryPush(100 + i));

    assert(!q.tryPush(999));
    assert(q.sizeSnapshot() == Queue.capacity);

    foreach_reverse (i; 0 .. Queue.capacity)
    {
        auto r = q.pop();

        assert(r.found);
        assert(r.value == 100 + i);
    }

    assert(q.emptySnapshot());
}

private void testPhysicalRingWraparound()
{
    Queue q;

    enum size_t rounds = 100_000;

    foreach (round; 0 .. rounds)
    {
        const base = round * Queue.capacity;

        foreach (i; 0 .. Queue.capacity)
            assert(q.tryPush(base + i + 1));

        if ((round & 1) == 0)
        {
            foreach (i; 0 .. Queue.capacity)
            {
                auto r = q.steal();

                assert(r.found);
                assert(r.value == base + i + 1);
            }
        }
        else
        {
            foreach_reverse (i; 0 .. Queue.capacity)
            {
                auto r = q.pop();

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

private void testCounterWrapBySteal()
{
    Queue q;

    /*
     * Four pushes cross:
     *
     *     ulong.max -> 0
     */
    q.researchSetEmptyIndex(ulong.max - 2);

    assert(q.tryPush(1));
    assert(q.tryPush(2));
    assert(q.tryPush(3));
    assert(q.tryPush(4));

    assert(q.sizeSnapshot() == 4);

    foreach (expected; 1 .. 5)
    {
        auto r = q.steal();

        assert(r.found);
        assert(r.value == expected);
    }

    assert(q.emptySnapshot());

    writefln(
        "stealWrap top=%s bottom=%s size=%s",
        q.researchTopSnapshot(),
        q.researchBottomSnapshot(),
        q.sizeSnapshot());
}

private void testCounterWrapByPop()
{
    Queue q;

    q.researchSetEmptyIndex(ulong.max - 2);

    assert(q.tryPush(1));
    assert(q.tryPush(2));
    assert(q.tryPush(3));
    assert(q.tryPush(4));

    foreach_reverse (expected; 1 .. 5)
    {
        auto r = q.pop();

        assert(r.found);
        assert(r.value == expected);
    }

    assert(q.emptySnapshot());

    writefln(
        "popWrap top=%s bottom=%s size=%s",
        q.researchTopSnapshot(),
        q.researchBottomSnapshot(),
        q.sizeSnapshot());
}

private void testCounterWrapMixed()
{
    Queue q;

    q.researchSetEmptyIndex(ulong.max - 2);

    assert(q.tryPush(11));
    assert(q.tryPush(22));
    assert(q.tryPush(33));
    assert(q.tryPush(44));

    auto a = q.steal();
    auto b = q.pop();
    auto c = q.steal();
    auto d = q.pop();

    assert(a.found && a.value == 11);
    assert(b.found && b.value == 44);
    assert(c.found && c.value == 22);
    assert(d.found && d.value == 33);

    assert(q.emptySnapshot());

    writefln(
        "mixedWrap top=%s bottom=%s size=%s",
        q.researchTopSnapshot(),
        q.researchBottomSnapshot(),
        q.sizeSnapshot());
}

private void testEmptyUnderflowAcrossZero()
{
    Queue q;

    /*
     * Empty owner pop at index zero makes the speculative local bottom
     * ulong.max before it is restored. It must still report empty.
     */
    q.researchSetEmptyIndex(0);

    auto r = q.pop();

    assert(!r.found);
    assert(q.emptySnapshot());
    assert(q.researchTopSnapshot() == 0);
    assert(q.researchBottomSnapshot() == 0);
}

void main()
{
    testOrdinarySemantics();
    testCapacity();
    testPhysicalRingWraparound();

    testCounterWrapBySteal();
    testCounterWrapByPop();
    testCounterWrapMixed();
    testEmptyUnderflowAcrossZero();

    writeln(
        "R0.1 P04b PASS: modulo-2^64 counter semantics preserve wraparound");
}
