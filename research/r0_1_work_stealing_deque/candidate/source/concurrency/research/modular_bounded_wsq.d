module concurrency.research.modular_bounded_wsq;

import concurrency.research.bounded_wsq : TakeResult;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicLoad,
    atomicStore,
    cas;

/**
 * Experimental bounded Chase-Lev deque using modulo-2^64 counters.
 *
 * This is a research comparison candidate, not public API.
 *
 * Exactly one owner may call tryPush and pop.
 * Zero or more thieves may call steal.
 *
 * The logical occupancy must never exceed capacity. Since capacity is far
 * below 2^63, modulo subtraction can distinguish the valid bounded occupancy
 * region from the speculative owner-underflow state.
 */
struct ModularBoundedWorkStealingDeque(T, size_t LogSize)
{
    static assert(LogSize > 0);
    static assert(LogSize < 63);

    enum size_t capacity = size_t(1) << LogSize;
    enum size_t mask = capacity - 1;

private:
    enum ulong counterCapacity = cast(ulong) capacity;
    enum ulong counterMask = cast(ulong) mask;

    shared ulong _top = 0;
    shared ulong _bottom = 0;

    shared T[capacity] _buffer;

public:
    bool tryPush(T item)
        @nogc nothrow
    {
        const b = atomicLoad!(MemoryOrder.raw)(_bottom);
        const t = atomicLoad!(MemoryOrder.acq)(_top);

        /*
         * Unsigned subtraction is intentionally modulo 2^64.
         *
         * In every valid stable state:
         *
         *     0 <= b - t <= capacity
         *
         * independent of whether the absolute counters crossed ulong.max.
         */
        const count = b - t;

        if (count >= counterCapacity)
            return false;

        atomicStore!(MemoryOrder.raw)(
            _buffer[cast(size_t)(b & counterMask)],
            item);

        atomicFence!(MemoryOrder.rel)();
        atomicStore!(MemoryOrder.rel)(_bottom, b + 1);

        return true;
    }

    TakeResult!T pop()
        @nogc nothrow
    {
        auto b = atomicLoad!(MemoryOrder.raw)(_bottom) - 1;
        atomicStore!(MemoryOrder.raw)(_bottom, b);

        atomicFence!(MemoryOrder.seq)();

        auto t = atomicLoad!(MemoryOrder.raw)(_top);

        /*
         * After the speculative decrement:
         *
         * queue had >= 2 items : distance = 1 .. capacity-1
         * queue had 1 item     : distance = 0
         * queue was empty      : distance = ulong.max
         *
         * This classification remains valid across ulong.max -> 0.
         */
        const distance = b - t;

        TakeResult!T result;

        if (distance < counterCapacity)
        {
            result.found = true;
            result.value = atomicLoad!(MemoryOrder.raw)(
                _buffer[cast(size_t)(b & counterMask)]);

            if (distance == 0)
            {
                if (!cas!(MemoryOrder.seq, MemoryOrder.raw)(
                        &_top, t, t + 1))
                {
                    result = TakeResult!T.init;
                }

                atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
            }
        }
        else
        {
            /*
             * Empty before the speculative decrement.
             */
            atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
        }

        return result;
    }

    TakeResult!T steal()
        @nogc nothrow
    {
        auto t = atomicLoad!(MemoryOrder.acq)(_top);

        atomicFence!(MemoryOrder.seq)();

        const b = atomicLoad!(MemoryOrder.acq)(_bottom);
        const count = b - t;

        TakeResult!T result;

        /*
         * A stable non-empty bounded queue has count in 1 .. capacity.
         *
         * A huge modular distance represents the transient owner-underflow
         * state and is therefore not stealable.
         */
        if (count != 0 && count <= counterCapacity)
        {
            result.value = atomicLoad!(MemoryOrder.raw)(
                _buffer[cast(size_t)(t & counterMask)]);

            if (cas!(MemoryOrder.seq, MemoryOrder.raw)(
                    &_top, t, t + 1))
            {
                result.found = true;
            }
        }

        return result;
    }

    size_t sizeSnapshot() const
        @nogc nothrow
    {
        const t = atomicLoad!(MemoryOrder.raw)(_top);
        const b = atomicLoad!(MemoryOrder.raw)(_bottom);
        const count = b - t;

        return count <= counterCapacity
            ? cast(size_t) count
            : 0;
    }

    bool emptySnapshot() const
        @nogc nothrow
    {
        return sizeSnapshot() == 0;
    }

    version (ConcurrencyResearchProbe)
    {
        void researchSetEmptyIndex(ulong index)
            @nogc nothrow
        {
            atomicStore!(MemoryOrder.raw)(_top, index);
            atomicStore!(MemoryOrder.raw)(_bottom, index);
        }

        ulong researchTopSnapshot() const
            @nogc nothrow
        {
            return atomicLoad!(MemoryOrder.raw)(_top);
        }

        ulong researchBottomSnapshot() const
            @nogc nothrow
        {
            return atomicLoad!(MemoryOrder.raw)(_bottom);
        }
    }
}
