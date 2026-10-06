module store_load_fence;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicFetchAdd;

extern(C)
void probe_reference_fence()
    @nogc nothrow
{
    atomicFence!(MemoryOrder.seq)();
}

extern(C)
void probe_local_rmw_fence()
    @nogc nothrow
{
    /*
     * Research-only candidate.
     *
     * The object exists only to express a seq_cst RMW in D.
     * Its value is intentionally unchanged.
     */
    shared int scratch = 0;

    atomicFetchAdd!(MemoryOrder.seq)(
        scratch,
        0);
}

extern(C)
void probe_external_rmw_fence(
    shared int* scratch)
    @nogc nothrow
{
    atomicFetchAdd!(MemoryOrder.seq)(
        *scratch,
        0);
}
