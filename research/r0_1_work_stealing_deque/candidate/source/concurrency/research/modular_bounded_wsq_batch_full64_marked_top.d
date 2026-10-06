module concurrency.research.modular_bounded_wsq_batch_full64_marked_top;

import concurrency.research.bounded_wsq :
    TakeResult;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicFetchAdd,
    atomicLoad,
    atomicStore,
    cas;

version (ConcurrencyResearchProbe)
{
    private shared bool _researchPauseBatchAfterMark;
    private shared bool _researchBatchMarked;
    private shared ulong _researchOwnerBusyRetries;
}

/*
 * P08g research candidate.
 *
 * Preserve the complete 64-bit modular top/bottom counter domain.
 *
 * A batch-in-progress state is represented by adding 2^63 to the raw
 * published top. Because this is a bounded deque with capacity < 2^63,
 * valid idle occupancy and marked occupancy occupy disjoint modular
 * distance ranges.
 *
 * idle:
 *
 *     bottom - rawTop in [0, capacity]
 *
 * busy:
 *
 *     bottom - rawTop in [2^63, 2^63 + capacity]
 *
 * Adding 2^63 twice modulo 2^64 restores the original raw top.
 */
private void researchSeqCstBarrier(
    shared int* fenceWord)
    @nogc nothrow
{
    version (LDC)
    {
        version (X86_64)
        {
            atomicFetchAdd!(
                MemoryOrder.seq)(
                    *fenceWord,
                    0);

            return;
        }
    }

    atomicFence!(MemoryOrder.seq)();
}

struct Full64DistanceMarkedBoundedWorkStealingDeque(
    T,
    size_t LogSize)
{
    static assert(LogSize > 0);
    static assert(LogSize < 63);

    enum size_t capacity =
        size_t(1) << LogSize;

    enum size_t mask =
        capacity - 1;

private:
    enum ulong halfRange =
        1UL << 63;

    enum ulong counterCapacity =
        cast(ulong) capacity;

    /*
     * Raw top state.
     *
     * Idle:
     *     _topState = logical top
     *
     * Busy:
     *     _topState = logical top + 2^63  (mod 2^64)
     */
    shared ulong _topState = 0;
    ubyte[56] _topPadding;

    shared ulong _bottom = 0;
    shared int _fenceWord = 0;
    ubyte[52] _bottomPadding;

    shared T[capacity] _buffer;

    static ulong markOrUnmark(
        ulong value)
        @nogc nothrow
    {
        return value + halfRange;
    }

    static ulong subtract(
        ulong lhs,
        ulong rhs)
        @nogc nothrow
    {
        /*
         * Intentional modulo-2^64 unsigned arithmetic.
         */
        return lhs - rhs;
    }

    static bool isIdleDistance(
        ulong distance)
        @nogc nothrow
    {
        return
            distance <=
            counterCapacity;
    }

    static bool isBusyDistance(
        ulong distance)
        @nogc nothrow
    {
        return
            distance >= halfRange &&
            distance <=
                halfRange +
                counterCapacity;
    }

    static bool isOwnerBusyDistance(
        ulong distance)
        @nogc nothrow
    {
        /*
         * Owner has already decremented bottom.
         *
         * For non-empty occupancy:
         *
         *     distance = 2^63 + occupancy - 1
         *
         * Empty+busy gives 2^63-1, which is conservatively handled as
         * empty/invalid rather than as a retry.
         */
        return
            distance >= halfRange &&
            distance <
                halfRange +
                counterCapacity;
    }

    static ulong logicalTopFromBusy(
        ulong rawState)
        @nogc nothrow
    {
        return markOrUnmark(
            rawState);
    }

public:
    bool tryPush(T item)
        @nogc nothrow
    {
        const b =
            atomicLoad!(
                MemoryOrder.raw)(
                    _bottom);

        const state =
            atomicLoad!(
                MemoryOrder.acq)(
                    _topState);

        const rawDistance =
            subtract(
                b,
                state);

        ulong t;
        ulong count;

        if (isIdleDistance(
                rawDistance))
        {
            t = state;
            count =
                rawDistance;
        }
        else if (isBusyDistance(
                     rawDistance))
        {
            /*
             * Recover the real full-width top while retaining conservative
             * capacity accounting during the batch copy.
             */
            t =
                logicalTopFromBusy(
                    state);

            count =
                subtract(
                    b,
                    t);
        }
        else
        {
            /*
             * Transient owner-pop state or otherwise non-canonical
             * observation. Refuse to overwrite anything.
             */
            return false;
        }

        if (count >= counterCapacity)
            return false;

        atomicStore!(
            MemoryOrder.raw)(
                _buffer[
                    cast(size_t)(
                        b &
                        cast(ulong) mask)],
                item);

        atomicFence!(
            MemoryOrder.rel)();

        atomicStore!(
            MemoryOrder.rel)(
                _bottom,
                b + 1);

        return true;
    }

    TakeResult!T pop()
        @nogc nothrow
    {
        for (;;)
        {
            const oldBottom =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _bottom);

            const b =
                oldBottom - 1;

            atomicStore!(
                MemoryOrder.raw)(
                    _bottom,
                    b);

            researchSeqCstBarrier(
                &_fenceWord);

            const state =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _topState);

            const rawDistance =
                subtract(
                    b,
                    state);

            /*
             * A non-empty batch reservation is active.
             *
             * Restore the speculative bottom decrement and retry.
             */
            if (isOwnerBusyDistance(
                    rawDistance))
            {
                atomicStore!(
                    MemoryOrder.raw)(
                        _bottom,
                        oldBottom);

                version (ConcurrencyResearchProbe)
                {
                    atomicFetchAdd!(
                        MemoryOrder.raw)(
                            _researchOwnerBusyRetries,
                            1);
                }

                continue;
            }

            TakeResult!T result;

            if (rawDistance < counterCapacity)
            {
                /*
                 * Valid non-empty idle state.
                 *
                 * Empty owner underflow is ulong.max and therefore does
                 * not enter here.
                 */
                result.found = true;

                result.value =
                    atomicLoad!(
                        MemoryOrder.raw)(
                            _buffer[
                                cast(size_t)(
                                    b &
                                    cast(ulong) mask)]);

                if (rawDistance == 0)
                {
                    auto expected =
                        state;

                    if (!cas!(
                            MemoryOrder.seq,
                            MemoryOrder.raw)(
                                &_topState,
                                expected,
                                state + 1))
                    {
                        result =
                            TakeResult!T.init;
                    }

                    atomicStore!(
                        MemoryOrder.raw)(
                            _bottom,
                            oldBottom);
                }
            }
            else
            {
                atomicStore!(
                    MemoryOrder.raw)(
                        _bottom,
                        oldBottom);
            }

            return result;
        }
    }

    TakeResult!T steal()
        @nogc nothrow
    {
        const state =
            atomicLoad!(
                MemoryOrder.acq)(
                    _topState);

        researchSeqCstBarrier(
            &_fenceWord);

        const b =
            atomicLoad!(
                MemoryOrder.acq)(
                    _bottom);

        const rawDistance =
            subtract(
                b,
                state);

        TakeResult!T result;

        /*
         * Only a valid idle occupancy may proceed.
         *
         * Busy states occupy the disjoint half-range marker interval.
         */
        if (
            rawDistance != 0 &&
            rawDistance <=
                counterCapacity)
        {
            result.value =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _buffer[
                            cast(size_t)(
                                state &
                                cast(ulong) mask)]);

            auto expected =
                state;

            if (cas!(
                    MemoryOrder.seq,
                    MemoryOrder.raw)(
                        &_topState,
                        expected,
                        state + 1))
            {
                result.found = true;
            }
        }

        return result;
    }

    size_t stealBatch(
        scope T[] output)
        @nogc nothrow
    {
        if (output.length == 0)
            return 0;

        /*
         * First observation exists only to distinguish a plausible idle
         * top from an already-marked state.
         *
         * The post-CAS bottom load is authoritative for the batch size.
         */
        const state =
            atomicLoad!(
                MemoryOrder.acq)(
                    _topState);

        /*
         * No SC fence is required between these observations.
         *
         * If state is a busy value published by another batch, the acquire
         * top load synchronizes with that publication and prevents bottom
         * from falling behind the state already observed by the marking
         * batch. P08g2c qualifies this property under RC11.
         *
         * If state is stale idle while another batch has already marked
         * top busy, the subsequent CAS using the stale state fails.
         */
        const beforeBottom =
            atomicLoad!(
                MemoryOrder.acq)(
                    _bottom);

        const beforeDistance =
            subtract(
                beforeBottom,
                state);

        if (
            beforeDistance == 0 ||
            beforeDistance >
                counterCapacity)
        {
            return 0;
        }

        /*
         * Atomically convert the exact observed full-width logical top into
         * its impossible-distance busy representation.
         */
        auto expected =
            state;

        const busyState =
            markOrUnmark(
                state);

        if (!cas!(
                MemoryOrder.seq,
                MemoryOrder.raw)(
                    &_topState,
                    expected,
                    busyState))
        {
            return 0;
        }

        version (ConcurrencyResearchProbe)
        {
            if (atomicLoad!(
                    MemoryOrder.acq)(
                        _researchPauseBatchAfterMark))
            {
                atomicStore!(
                    MemoryOrder.rel)(
                        _researchBatchMarked,
                        true);

                while (atomicLoad!(
                        MemoryOrder.acq)(
                            _researchPauseBatchAfterMark))
                {
                }
            }
        }

        /*
         * This is the critical P08d0 ordering edge.
         *
         * If owner pop was ordered first, this load must include its
         * speculative bottom decrement or a later bottom state.
         */
        researchSeqCstBarrier(
            &_fenceWord);

        const b =
            atomicLoad!(
                MemoryOrder.acq)(
                    _bottom);

        const available =
            subtract(
                b,
                state);

        if (
            available == 0 ||
            available >
                counterCapacity)
        {
            /*
             * No valid batch remains. Restore the exact original full-width
             * logical top.
             */
            atomicStore!(
                MemoryOrder.rel)(
                    _topState,
                    state);

            return 0;
        }

        size_t take =
            cast(size_t) available;

        if (take > output.length)
            take = output.length;

        foreach (i; 0 .. take)
        {
            const index =
                state +
                cast(ulong) i;

            output[i] =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _buffer[
                            cast(size_t)(
                                index &
                                cast(ulong) mask)]);
        }

        /*
         * Publish the new full-width logical top and clear busy in the same
         * store.
         */
        atomicStore!(
            MemoryOrder.rel)(
                _topState,
                state +
                cast(ulong) take);

        return take;
    }

    size_t sizeSnapshot() const
        @nogc nothrow
    {
        const state =
            atomicLoad!(
                MemoryOrder.raw)(
                    _topState);

        const b =
            atomicLoad!(
                MemoryOrder.raw)(
                    _bottom);

        const rawDistance =
            subtract(
                b,
                state);

        if (rawDistance <= counterCapacity)
        {
            return
                cast(size_t)
                    rawDistance;
        }

        if (isBusyDistance(
                rawDistance))
        {
            return
                cast(size_t)(
                    rawDistance -
                    halfRange);
        }

        return 0;
    }

    bool emptySnapshot() const
        @nogc nothrow
    {
        return
            sizeSnapshot() == 0;
    }

    version (ConcurrencyResearchProbe)
    {
        void researchSetEmptyIndex(
            ulong index)
            @nogc nothrow
        {
            atomicStore!(
                MemoryOrder.raw)(
                    _topState,
                    index);

            atomicStore!(
                MemoryOrder.raw)(
                    _bottom,
                    index);
        }

        ulong researchTopSnapshot() const
            @nogc nothrow
        {
            const state =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _topState);

            const b =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _bottom);

            const d =
                subtract(
                    b,
                    state);

            return
                isBusyDistance(d)
                    ? logicalTopFromBusy(state)
                    : state;
        }

        ulong researchRawTopSnapshot() const
            @nogc nothrow
        {
            return atomicLoad!(
                MemoryOrder.raw)(
                    _topState);
        }

        ulong researchBottomSnapshot() const
            @nogc nothrow
        {
            return
                atomicLoad!(
                    MemoryOrder.raw)(
                        _bottom);
        }

        bool researchBatchBusy() const
            @nogc nothrow
        {
            const state =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _topState);

            const b =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _bottom);

            return isBusyDistance(
                subtract(
                    b,
                    state));
        }

        enum ulong researchCounterMask =
            ulong.max;

        enum ulong researchBusyOffset =
            halfRange;

        void researchEnableBatchPause()
            @nogc nothrow
        {
            atomicStore!(
                MemoryOrder.raw)(
                    _researchBatchMarked,
                    false);

            atomicStore!(
                MemoryOrder.raw)(
                    _researchOwnerBusyRetries,
                    0);

            atomicStore!(
                MemoryOrder.rel)(
                    _researchPauseBatchAfterMark,
                    true);
        }

        void researchReleaseBatchPause()
            @nogc nothrow
        {
            atomicStore!(
                MemoryOrder.rel)(
                    _researchPauseBatchAfterMark,
                    false);
        }

        bool researchBatchMarkedSnapshot() const
            @nogc nothrow
        {
            return atomicLoad!(
                MemoryOrder.acq)(
                    _researchBatchMarked);
        }

        void researchResetOwnerBusyRetries()
            @nogc nothrow
        {
            atomicStore!(
                MemoryOrder.raw)(
                    _researchOwnerBusyRetries,
                    0);
        }

        ulong researchOwnerBusyRetriesSnapshot() const
            @nogc nothrow
        {
            return atomicLoad!(
                MemoryOrder.acq)(
                    _researchOwnerBusyRetries);
        }
    }
}
