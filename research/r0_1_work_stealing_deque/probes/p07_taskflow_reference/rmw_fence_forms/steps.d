module steps;

import core.atomic :
    MemoryOrder,
    atomicExchange,
    atomicFetchAdd,
    atomicFence,
    atomicLoad,
    atomicStore,
    cas;

private long prefix(
    shared long* bottom)
    @nogc nothrow
{
    auto b =
        atomicLoad!(MemoryOrder.raw)(*bottom) - 1;

    atomicStore!(MemoryOrder.raw)(
        *bottom,
        b);

    return b;
}

extern(C)
long step_mfence(
    shared long* top,
    shared long* bottom,
    shared long*)
    @nogc nothrow
{
    const b = prefix(bottom);

    atomicFence!(MemoryOrder.seq)();

    return b -
        atomicLoad!(MemoryOrder.raw)(*top);
}

extern(C)
long step_cas(
    shared long* top,
    shared long* bottom,
    shared long* scratch)
    @nogc nothrow
{
    const b = prefix(bottom);

    long expected =
        atomicLoad!(MemoryOrder.raw)(*scratch);

    if (!cas!(
            MemoryOrder.seq,
            MemoryOrder.raw)(
                scratch,
                expected,
                expected))
        return long.min;

    return b -
        atomicLoad!(MemoryOrder.raw)(*top);
}

extern(C)
long step_fetch_add(
    shared long* top,
    shared long* bottom,
    shared long* scratch)
    @nogc nothrow
{
    const b = prefix(bottom);

    /*
     * seq_cst atomic RMW; modifier zero preserves the value.
     */
    atomicFetchAdd!(MemoryOrder.seq)(
        *scratch,
        0);

    return b -
        atomicLoad!(MemoryOrder.raw)(*top);
}

extern(C)
long step_exchange(
    shared long* top,
    shared long* bottom,
    shared long* scratch)
    @nogc nothrow
{
    const b = prefix(bottom);

    const value =
        atomicLoad!(MemoryOrder.raw)(*scratch);

    atomicExchange!(MemoryOrder.seq)(
        scratch,
        value);

    return b -
        atomicLoad!(MemoryOrder.raw)(*top);
}
