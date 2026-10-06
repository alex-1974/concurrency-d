module concurrency.research.bounded_wsq;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicLoad,
    atomicStore,
    cas;

/**
 * Result of a fallible deque removal operation.
 *
 * P01 intentionally avoids reserving an element value as an empty sentinel.
 */
struct TakeResult(T)
{
    bool found;
    T value;
}

/**
 * Experimental bounded single-owner / multi-thief Chase-Lev deque.
 *
 * This is a research candidate, not public concurrency-d API.
 *
 * Exactly one owner may call tryPush and pop.
 * Any number of thieves may call steal.
 *
 * LogSize is log2(capacity).
 */
struct BoundedWorkStealingDeque(T, size_t LogSize)
{
    static assert(LogSize > 0);
    static assert(LogSize < size_t.sizeof * 8);

    enum size_t capacity = size_t(1) << LogSize;
    enum size_t mask = capacity - 1;

private:
    // Signed monotonic indices match the reference algorithm's arithmetic.
    //
    // Layout/cache-line separation is deliberately NOT tuned in P01.
    // P08 owns that research question.
    shared long _top = 0;
    shared long _bottom = 0;

    shared T[capacity] _buffer;

public:
    /**
     * Owner-only push.
     *
     * Returns false when the bounded local deque is full.
     */
    bool tryPush(T item)
        @nogc nothrow
    {
        const b = atomicLoad!(MemoryOrder.raw)(_bottom);
        const t = atomicLoad!(MemoryOrder.acq)(_top);

        if (cast(ulong)(b - t + 1) > capacity)
            return false;

        atomicStore!(MemoryOrder.raw)(
            _buffer[cast(size_t)b & mask],
            item);

        atomicFence!(MemoryOrder.rel)();

        // Taskflow currently uses release here rather than the relaxed store
        // in the original paper, partly for sanitizer/tooling compatibility.
        atomicStore!(MemoryOrder.rel)(_bottom, b + 1);

        return true;
    }

    /**
     * Owner-only LIFO removal.
     */
    TakeResult!T pop()
        @nogc nothrow
    {
        auto b = atomicLoad!(MemoryOrder.raw)(_bottom) - 1;
        atomicStore!(MemoryOrder.raw)(_bottom, b);

        // Required by the reference race protocol between owner pop and steal.
        atomicFence!(MemoryOrder.seq)();

        auto t = atomicLoad!(MemoryOrder.raw)(_top);

        TakeResult!T result;

        if (t <= b)
        {
            result.found = true;
            result.value = atomicLoad!(MemoryOrder.raw)(
                _buffer[cast(size_t)b & mask]);

            if (t == b)
            {
                // Last element: owner and thieves race for top.
                if (!cas!(MemoryOrder.seq, MemoryOrder.raw)(
                        &_top, t, t + 1))
                {
                    result = TakeResult!T.init;
                }

                // Restore the canonical empty-state bottom.
                atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
            }
        }
        else
        {
            // Empty: undo speculative bottom decrement.
            atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
        }

        return result;
    }

    /**
     * Thief-side FIFO removal from the opposite end.
     */
    TakeResult!T steal()
        @nogc nothrow
    {
        auto t = atomicLoad!(MemoryOrder.acq)(_top);

        atomicFence!(MemoryOrder.seq)();

        const b = atomicLoad!(MemoryOrder.acq)(_bottom);

        TakeResult!T result;

        if (t < b)
        {
            result.value = atomicLoad!(MemoryOrder.raw)(
                _buffer[cast(size_t)t & mask]);

            if (cas!(MemoryOrder.seq, MemoryOrder.raw)(
                    &_top, t, t + 1))
            {
                result.found = true;
            }
        }

        return result;
    }

    /**
     * Snapshot size for diagnostics/tests.
     *
     * This is not a synchronization primitive.
     */
    size_t sizeSnapshot() const
        @nogc nothrow
    {
        const t = atomicLoad!(MemoryOrder.raw)(_top);
        const b = atomicLoad!(MemoryOrder.raw)(_bottom);

        return b > t ? cast(size_t)(b - t) : 0;
    }

    bool emptySnapshot() const
        @nogc nothrow
    {
        return sizeSnapshot() == 0;
    }
}
