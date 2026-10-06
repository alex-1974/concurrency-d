module concurrency.research.modular_bounded_wsq_batch_marked_top;

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
 * P08e research candidate.
 *
 * One bit of the 64-bit top state is used as an in-progress batch marker.
 * The remaining 63 bits form the modular top counter.
 *
 * This deliberately reduces the research counter domain from 2^64 to 2^63.
 * It is NOT yet a production contract.
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

struct MarkedTopBatchBoundedWorkStealingDeque(
    T,
    size_t LogSize)
{
    static assert(LogSize > 0);
    static assert(LogSize < 62);

    enum size_t capacity =
        size_t(1) << LogSize;

    enum size_t mask =
        capacity - 1;

private:
    enum ulong counterMask =
        ulong.max >> 1;

    enum ulong counterCapacity =
        cast(ulong) capacity;

    enum ulong busyBit = 1;

    /*
     * Encoded state:
     *
     *     bits 63..1 = 63-bit modular top
     *     bit  0     = batch busy marker
     */
    shared ulong _topState = 0;
    ubyte[56] _topPadding;

    shared ulong _bottom = 0;
    shared int _fenceWord = 0;
    ubyte[52] _bottomPadding;

    shared T[capacity] _buffer;

    static ulong encodeTop(
        ulong top,
        bool busy)
        @nogc nothrow
    {
        return
            ((top & counterMask) << 1) |
            (busy ? busyBit : 0);
    }

    static ulong decodeTop(
        ulong state)
        @nogc nothrow
    {
        return
            (state >> 1) &
            counterMask;
    }

    static bool isBusy(
        ulong state)
        @nogc nothrow
    {
        return
            (state & busyBit) != 0;
    }

    static ulong increment(
        ulong value)
        @nogc nothrow
    {
        return
            (value + 1) &
            counterMask;
    }

    static ulong addCounter(
        ulong value,
        size_t amount)
        @nogc nothrow
    {
        return
            (value +
                cast(ulong) amount) &
            counterMask;
    }

    static ulong subtract(
        ulong lhs,
        ulong rhs)
        @nogc nothrow
    {
        return
            (lhs - rhs) &
            counterMask;
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

        /*
         * While a batch is active, use its still-published old top.
         * This is conservative for capacity and prevents slot reuse while
         * the batch copies reserved values.
         */
        const t =
            decodeTop(state);

        const count =
            subtract(b, t);

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
                increment(b));

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
                (oldBottom - 1) &
                counterMask;

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

            /*
             * A batch reservation started before this owner reached the
             * top observation point.
             *
             * Restore the speculative bottom decrement and retry.
             *
             * Normal uncontended owner pops perform no additional CAS.
             */
            if (isBusy(state))
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

            const t =
                decodeTop(state);

            const distance =
                subtract(b, t);

            TakeResult!T result;

            if (distance < counterCapacity)
            {
                result.found = true;

                result.value =
                    atomicLoad!(
                        MemoryOrder.raw)(
                            _buffer[
                                cast(size_t)(
                                    b &
                                    cast(ulong) mask)]);

                if (distance == 0)
                {
                    auto expected =
                        state;

                    const next =
                        encodeTop(
                            increment(t),
                            false);

                    if (!cas!(
                            MemoryOrder.seq,
                            MemoryOrder.raw)(
                                &_topState,
                                expected,
                                next))
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

        TakeResult!T result;

        if (isBusy(state))
            return result;

        const t =
            decodeTop(state);

        researchSeqCstBarrier(
            &_fenceWord);

        const b =
            atomicLoad!(
                MemoryOrder.acq)(
                    _bottom);

        const count =
            subtract(b, t);

        if (
            count != 0 &&
            count <= counterCapacity)
        {
            result.value =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _buffer[
                            cast(size_t)(
                                t &
                                cast(ulong) mask)]);

            auto expected =
                state;

            if (cas!(
                    MemoryOrder.seq,
                    MemoryOrder.raw)(
                        &_topState,
                        expected,
                        encodeTop(
                            increment(t),
                            false)))
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

        const state =
            atomicLoad!(
                MemoryOrder.acq)(
                    _topState);

        if (isBusy(state))
            return 0;

        const t =
            decodeTop(state);

        /*
         * Phase 1:
         * publish the in-progress marker before observing bottom.
         *
         * New thieves cannot claim top while this marker is present.
         * Owner pop will restore its speculative decrement and retry if it
         * reaches its top observation after this point.
         */
        auto expected =
            state;

        const busyState =
            encodeTop(
                t,
                true);

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

        researchSeqCstBarrier(
            &_fenceWord);

        const b =
            atomicLoad!(
                MemoryOrder.acq)(
                    _bottom);

        const available =
            subtract(b, t);

        if (
            available == 0 ||
            available > counterCapacity)
        {
            atomicStore!(
                MemoryOrder.rel)(
                    _topState,
                    encodeTop(
                        t,
                        false));

            return 0;
        }

        size_t take =
            cast(size_t) available;

        if (take > output.length)
            take = output.length;

        foreach (i; 0 .. take)
        {
            const index =
                addCounter(
                    t,
                    i);

            output[i] =
                atomicLoad!(
                    MemoryOrder.raw)(
                        _buffer[
                            cast(size_t)(
                                index &
                                cast(ulong) mask)]);
        }

        /*
         * Phase 2:
         * publish the new top and release ordinary stealers/owner.
         */
        atomicStore!(
            MemoryOrder.rel)(
                _topState,
                encodeTop(
                    addCounter(
                        t,
                        take),
                    false));

        return take;
    }

    size_t sizeSnapshot() const
        @nogc nothrow
    {
        const state =
            atomicLoad!(
                MemoryOrder.raw)(
                    _topState);

        const t =
            decodeTop(state);

        const b =
            atomicLoad!(
                MemoryOrder.raw)(
                    _bottom);

        const count =
            subtract(b, t);

        return
            count <= counterCapacity
                ? cast(size_t) count
                : 0;
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
            const normalized =
                index &
                counterMask;

            atomicStore!(
                MemoryOrder.raw)(
                    _topState,
                    encodeTop(
                        normalized,
                        false));

            atomicStore!(
                MemoryOrder.raw)(
                    _bottom,
                    normalized);
        }

        ulong researchTopSnapshot() const
            @nogc nothrow
        {
            return decodeTop(
                atomicLoad!(
                    MemoryOrder.raw)(
                        _topState));
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
            return isBusy(
                atomicLoad!(
                    MemoryOrder.raw)(
                        _topState));
        }

        enum ulong researchCounterMask =
            counterMask;

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
