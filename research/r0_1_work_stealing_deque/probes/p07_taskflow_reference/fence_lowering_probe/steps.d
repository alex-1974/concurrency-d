module steps;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicLoad,
    atomicStore,
    cas;

extern(C)
long d_step_mfence(
    shared long* top,
    shared long* bottom)
    @nogc nothrow
{
    auto b =
        atomicLoad!(MemoryOrder.raw)(*bottom) - 1;

    atomicStore!(MemoryOrder.raw)(
        *bottom,
        b);

    atomicFence!(MemoryOrder.seq)();

    const t =
        atomicLoad!(MemoryOrder.raw)(*top);

    return b - t;
}

extern(C)
long d_step_seq_cas(
    shared long* top,
    shared long* bottom,
    shared long* fenceWord)
    @nogc nothrow
{
    auto b =
        atomicLoad!(MemoryOrder.raw)(*bottom) - 1;

    atomicStore!(MemoryOrder.raw)(
        *bottom,
        b);

    /*
     * Research candidate only:
     *
     * A successful seq_cst RMW on an independent atomic is used here to
     * test whether a locked instruction provides the required full ordering
     * at substantially lower x86 cost than LDC's atomicFence(seq) -> mfence.
     *
     * Semantic equivalence to the required Chase-Lev fence is NOT assumed
     * by this probe and must be justified separately before any use in the
     * queue implementation.
     */
    long expected =
        atomicLoad!(MemoryOrder.raw)(*fenceWord);

    const ok =
        cas!(
            MemoryOrder.seq,
            MemoryOrder.raw)(
                fenceWord,
                expected,
                expected);

    if (!ok)
        return long.min;

    const t =
        atomicLoad!(MemoryOrder.raw)(*top);

    return b - t;
}
