module concurrency.research.modular_bounded_wsq_batch_gate;

import concurrency.research.bounded_wsq : TakeResult;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicFetchAdd,
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
/*
 * Research-only seq_cst barrier candidate.
 *
 * LDC/x86_64 qualification has shown that an unused idempotent seq_cst RMW
 * is lowered by optimized LLVM code generation to a locked instruction
 * equivalent in shape to the GCC/Taskflow seq_cst-fence lowering.
 *
 * This is NOT a general replacement for atomicFence(seq).
 *
 * It exists only to qualify the Chase-Lev ordering points under the exact
 * R0.1 contract. Other compilers and architectures retain the established
 * atomicFence(seq) implementation.
 */
private void researchSeqCstBarrier(shared int* fenceWord)
    @nogc nothrow
{
    version (LDC)
    {
        version (X86_64)
        {
            /*
             * The value is deliberately unchanged.
             *
             * Optimized LDC/LLVM x86_64 code generation must be independently
             * checked by the R0.1 codegen gate before performance claims are
             * accepted.
             */
            atomicFetchAdd!(MemoryOrder.seq)(
                *fenceWord,
                0);

            return;
        }
    }

    atomicFence!(MemoryOrder.seq)();
}

struct GatedBatchBoundedWorkStealingDeque(T, size_t LogSize)
{
    static assert(LogSize > 0);
    static assert(LogSize < 63);

    enum size_t capacity = size_t(1) << LogSize;
    enum size_t mask = capacity - 1;

private:
    enum ulong counterCapacity = cast(ulong) capacity;
    enum ulong counterMask = cast(ulong) mask;

    /*
     * P08 Taskflow-layout control.
     *
     * Relevant offsets for T == size_t:
     *
     *     top       0x00
     *     bottom    0x40
     *     buffer    0x80
     *
     * The research-only fence operand lives in otherwise-unused padding
     * between bottom and buffer.
     */
    shared ulong _top = 0;
    ubyte[56] _topPadding;

    shared ulong _bottom = 0;
    shared int _fenceWord = 0;

    /*
     * P08d2 research-only coordination between owner pop and a multi-item
     * thief claim.
     *
     * This consumes existing padding and therefore preserves:
     *
     *     top       +0x00
     *     bottom    +0x40
     *     buffer    +0x80
     */
    shared int _batchClaimGate = 0;
    ubyte[48] _bottomPadding;

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

    private void lockBatchClaimGate()
        @nogc nothrow
    {
        for (;;)
        {
            int expected = 0;

            if (cas!(
                    MemoryOrder.acq,
                    MemoryOrder.raw)(
                        &_batchClaimGate,
                        expected,
                        1))
            {
                return;
            }
        }
    }

    private void unlockBatchClaimGate()
        @nogc nothrow
    {
        atomicStore!(
            MemoryOrder.rel)(
                _batchClaimGate,
                0);
    }

    private TakeResult!T popUnlocked()
        @nogc nothrow
    {
        auto b = atomicLoad!(MemoryOrder.raw)(_bottom) - 1;
        atomicStore!(MemoryOrder.raw)(_bottom, b);

        researchSeqCstBarrier(&_fenceWord);

        auto t = atomicLoad!(MemoryOrder.raw)(_top);

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
            atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
        }

        return result;
    }

    TakeResult!T pop()
        @nogc nothrow
    {
        lockBatchClaimGate();

        const result =
            popUnlocked();

        unlockBatchClaimGate();

        return result;
    }

    TakeResult!T steal()
        @nogc nothrow
    {
        auto t = atomicLoad!(MemoryOrder.acq)(_top);

        researchSeqCstBarrier(&_fenceWord);

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

    /*
     * P08d2 research candidate.
     *
     * Owner pop and batch reservation are serialized by _batchClaimGate.
     *
     * Candidate slots are read before advancing top. While top still names
     * those slots, owner push cannot legally wrap around and overwrite them.
     * The gate prevents owner pop from consuming the opposite end while the
     * batch snapshot and claim are being established.
     *
     * Ordinary single-item thieves remain CAS-coordinated through _top. If
     * one wins while this batch is being prepared, the batch CAS fails and
     * returns zero.
     */
    size_t stealBatch(scope T[] output)
        @nogc nothrow
    {
        if (output.length == 0)
            return 0;

        lockBatchClaimGate();

        const t =
            atomicLoad!(MemoryOrder.acq)(_top);

        researchSeqCstBarrier(
            &_fenceWord);

        const b =
            atomicLoad!(MemoryOrder.acq)(_bottom);

        const available =
            b - t;

        if (
            available == 0 ||
            available > counterCapacity)
        {
            unlockBatchClaimGate();
            return 0;
        }

        size_t take =
            cast(size_t) available;

        if (take > output.length)
            take = output.length;

        foreach (i; 0 .. take)
        {
            const index =
                t + cast(ulong) i;

            output[i] =
                atomicLoad!(MemoryOrder.raw)(
                    _buffer[
                        cast(size_t)(
                            index &
                            counterMask)]);
        }

        auto expected =
            t;

        const claimed =
            cas!(
                MemoryOrder.seq,
                MemoryOrder.raw)(
                    &_top,
                    expected,
                    t + cast(ulong) take);

        unlockBatchClaimGate();

        return claimed
            ? take
            : 0;
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
