module app;

import concurrency.research.bounded_wsq :
    BoundedWorkStealingDeque;

alias Queue = BoundedWorkStealingDeque!(size_t, 3);

private void testInitialState()
{
    Queue q;

    assert(q.capacity == 8);
    assert(q.emptySnapshot());
    assert(q.sizeSnapshot() == 0);

    auto p = q.pop();
    assert(!p.found);

    auto s = q.steal();
    assert(!s.found);

    assert(q.emptySnapshot());
}

private void testOwnerLifo()
{
    Queue q;

    assert(q.tryPush(11));
    assert(q.tryPush(22));
    assert(q.tryPush(33));

    assert(q.sizeSnapshot() == 3);

    auto a = q.pop();
    auto b = q.pop();
    auto c = q.pop();
    auto d = q.pop();

    assert(a.found && a.value == 33);
    assert(b.found && b.value == 22);
    assert(c.found && c.value == 11);
    assert(!d.found);

    assert(q.emptySnapshot());
}

private void testThiefFifo()
{
    Queue q;

    assert(q.tryPush(11));
    assert(q.tryPush(22));
    assert(q.tryPush(33));
    assert(q.tryPush(44));

    auto a = q.steal();
    auto b = q.steal();

    assert(a.found && a.value == 11);
    assert(b.found && b.value == 22);

    auto c = q.pop();
    auto d = q.pop();

    assert(c.found && c.value == 44);
    assert(d.found && d.value == 33);

    assert(!q.pop().found);
    assert(!q.steal().found);
    assert(q.emptySnapshot());
}

private void testCapacity()
{
    Queue q;

    foreach (i; 0 .. Queue.capacity)
        assert(q.tryPush(100 + i));

    assert(q.sizeSnapshot() == Queue.capacity);

    // A bounded local queue must not overwrite a live slot.
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

private void testRingSlotReuse()
{
    Queue q;

    // Advance logical indices through many physical ring wraps.
    foreach (round; 0 .. 1_000)
    {
        foreach (i; 0 .. Queue.capacity)
            assert(q.tryPush(round * 100 + i + 1));

        foreach (i; 0 .. Queue.capacity)
        {
            auto r = q.steal();
            assert(r.found);
            assert(r.value == round * 100 + i + 1);
        }

        assert(q.emptySnapshot());
    }
}

private void testMixedEnds()
{
    Queue q;

    assert(q.tryPush(1));
    assert(q.tryPush(2));
    assert(q.tryPush(3));
    assert(q.tryPush(4));

    auto oldest = q.steal();
    auto newest = q.pop();

    assert(oldest.found && oldest.value == 1);
    assert(newest.found && newest.value == 4);

    assert(q.tryPush(5));

    auto nextOldest = q.steal();
    auto nextNewest = q.pop();
    auto last = q.pop();

    assert(nextOldest.found && nextOldest.value == 2);
    assert(nextNewest.found && nextNewest.value == 5);
    assert(last.found && last.value == 3);

    assert(q.emptySnapshot());
}

void main()
{
    testInitialState();
    testOwnerLifo();
    testThiefFifo();
    testCapacity();
    testRingSlotReuse();
    testMixedEnds();

    import std.stdio : writeln;
    writeln("R0.1 P01 PASS: bounded sequential invariants");
}
