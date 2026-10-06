module protocol_step;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicLoad,
    atomicStore;

extern(C)
long d_pop_protocol_step(
    shared long* top,
    shared long* bottom)
    @nogc nothrow
{
    auto b =
        atomicLoad!(MemoryOrder.raw)(
            *bottom) - 1;

    atomicStore!(MemoryOrder.raw)(
        *bottom,
        b);

    atomicFence!(MemoryOrder.seq)();

    const t =
        atomicLoad!(MemoryOrder.raw)(
            *top);

    return b - t;
}
