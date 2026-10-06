module app;

import concurrency.research.bounded_wsq :
    BoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import std.stdio : writeln;

alias SignedQueue =
    BoundedWorkStealingDeque!(size_t, 8);

alias ModularQueue =
    ModularBoundedWorkStealingDeque!(size_t, 8);

/*
 * Stable C symbols make compiler/disassembly comparison straightforward.
 *
 * The queue methods are intentionally allowed to inline into these wrappers.
 */

extern(C)
bool probe_signed_push(
    SignedQueue* queue,
    size_t value)
    @nogc nothrow
{
    return queue.tryPush(value);
}

extern(C)
bool probe_modular_push(
    ModularQueue* queue,
    size_t value)
    @nogc nothrow
{
    return queue.tryPush(value);
}

extern(C)
size_t probe_signed_pop(
    SignedQueue* queue,
    bool* found)
    @nogc nothrow
{
    const result = queue.pop();

    *found = result.found;

    return result.value;
}

extern(C)
size_t probe_modular_pop(
    ModularQueue* queue,
    bool* found)
    @nogc nothrow
{
    const result = queue.pop();

    *found = result.found;

    return result.value;
}

extern(C)
size_t probe_signed_steal(
    SignedQueue* queue,
    bool* found)
    @nogc nothrow
{
    const result = queue.steal();

    *found = result.found;

    return result.value;
}

extern(C)
size_t probe_modular_steal(
    ModularQueue* queue,
    bool* found)
    @nogc nothrow
{
    const result = queue.steal();

    *found = result.found;

    return result.value;
}

private size_t exerciseSigned()
{
    SignedQueue queue;
    size_t checksum;
    bool found;

    foreach (i; 1 .. 129)
        assert(probe_signed_push(&queue, i));

    foreach (_; 0 .. 64)
    {
        const value =
            probe_signed_steal(&queue, &found);

        assert(found);
        checksum += value;
    }

    foreach (_; 0 .. 64)
    {
        const value =
            probe_signed_pop(&queue, &found);

        assert(found);
        checksum += value;
    }

    assert(queue.emptySnapshot());

    return checksum;
}

private size_t exerciseModular()
{
    ModularQueue queue;
    size_t checksum;
    bool found;

    foreach (i; 1 .. 129)
        assert(probe_modular_push(&queue, i));

    foreach (_; 0 .. 64)
    {
        const value =
            probe_modular_steal(&queue, &found);

        assert(found);
        checksum += value;
    }

    foreach (_; 0 .. 64)
    {
        const value =
            probe_modular_pop(&queue, &found);

        assert(found);
        checksum += value;
    }

    assert(queue.emptySnapshot());

    return checksum;
}

void main()
{
    const signedChecksum =
        exerciseSigned();

    const modularChecksum =
        exerciseModular();

    assert(signedChecksum == modularChecksum);

    writeln(
        "R0.1 P05 PASS: signed/modular semantic checksum=",
        signedChecksum);
}
