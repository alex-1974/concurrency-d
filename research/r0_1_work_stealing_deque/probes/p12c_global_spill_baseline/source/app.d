module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicOp,
    atomicStore;

import core.sync.mutex :
    Mutex;

import core.thread :
    Thread;

version (linux)
{
    import core.sys.linux.sched :
        CPU_SET,
        cpu_set_t,
        sched_getcpu,
        sched_setaffinity;
}

import std.algorithm.sorting :
    sort;

import std.datetime.stopwatch :
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t LogSize = 10;
enum size_t Capacity = size_t(1) << LogSize;

enum size_t Thieves = 4;
enum size_t BatchSize = 8;

enum size_t Tasks = 262_144;

enum size_t Warmups = 2;
enum size_t Samples = 9;

enum size_t OwnerCpu = 2;

enum OverflowPolicy
{
    retry,
    executeInline,
    globalSpill
}

struct TaskRef
{
    ulong value;
}

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        TaskRef,
        LogSize);

/*
 * Deliberately simple P12 reference structure.
 *
 * This is not a proposed production queue.
 *
 * It is:
 * - preallocated;
 * - bounded to the total benchmark task count;
 * - FIFO;
 * - protected by one ordinary mutex;
 * - non-resizing.
 *
 * Slots are not recycled because at most Tasks elements can ever be
 * inserted during one benchmark run. This keeps the reference mechanism
 * structurally simple and avoids introducing another ring-buffer design
 * question into P12.
 */
final class SpillQueue
{
private:
    Mutex _mutex;
    TaskRef[] _buffer;

    size_t _head;
    size_t _tail;

public:
    this(size_t capacity)
    {
        _mutex =
            new Mutex;

        _buffer =
            new TaskRef[capacity];
    }

    bool push(
        TaskRef task)
    {
        _mutex.lock();

        scope (exit)
            _mutex.unlock();

        if (
            _tail >=
            _buffer.length)
        {
            return false;
        }

        _buffer[_tail] =
            task;

        ++_tail;

        return true;
    }

    size_t popBatch(
        scope TaskRef[] output)
    {
        if (output.length == 0)
            return 0;

        _mutex.lock();

        scope (exit)
            _mutex.unlock();

        const available =
            _tail - _head;

        if (available == 0)
            return 0;

        size_t take =
            available;

        if (take > output.length)
            take =
                output.length;

        foreach (i; 0 .. take)
        {
            output[i] =
                _buffer[
                    _head + i];
        }

        _head +=
            take;

        return take;
    }

    bool empty()
    {
        _mutex.lock();

        scope (exit)
            _mutex.unlock();

        return
            _head == _tail;
    }
}

struct RunResult
{
    ulong elapsedNs;

    size_t ownerExecuted;
    size_t stolenExecuted;
    size_t inlineExecuted;
    size_t spillExecuted;

    size_t fullEvents;
    size_t retryAttempts;

    size_t localClaims;
    size_t spillPushes;
    size_t spillClaims;

    ulong valueSum;
    ulong valueXor;
    ulong workChecksum;
}

struct Stats
{
    double median;
    double p10;
    double p90;
}

private void pinCurrentThread(
    size_t cpu)
{
    version (linux)
    {
        cpu_set_t mask;

        CPU_SET(
            cpu,
            &mask);

        if (
            sched_setaffinity(
                0,
                cpu_set_t.sizeof,
                &mask) != 0)
        {
            throw new Exception(
                "sched_setaffinity failed");
        }

        const actual =
            sched_getcpu();

        if (
            actual < 0 ||
            cast(size_t) actual != cpu)
        {
            throw new Exception(
                "affinity verification failed");
        }
    }
    else
    {
        throw new Exception(
            "Linux affinity required");
    }
}

private ulong doWork(
    ulong value,
    size_t rounds)
    @safe @nogc nothrow
{
    ulong x =
        value +
        0x9e3779b97f4a7c15UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;

        x *=
            0x2545f4914f6cdd1dUL;

        x +=
            cast(ulong) i +
            0x9e3779b97f4a7c15UL;
    }

    return x;
}

private ulong expectedWorkChecksum(
    size_t rounds)
{
    ulong result;

    foreach (i; 0 .. Tasks)
    {
        result ^=
            doWork(
                cast(ulong) i + 1,
                rounds);
    }

    return result;
}

private RunResult run(
    OverflowPolicy policy,
    size_t rounds)
{
    auto queue =
        new Queue;

    auto spill =
        new SpillQueue(
            Tasks);

    shared bool start;
    shared bool producerDone;

    shared size_t readyCount;

    shared size_t stolenExecuted;
    shared size_t spillExecuted;

    shared size_t localClaims;
    shared size_t spillClaims;

    shared ulong stolenSum;
    shared ulong stolenXor;
    shared ulong stolenWork;

    Thread[Thieves] thieves;

    foreach (thiefIndex; 0 .. Thieves)
    {
        thieves[thiefIndex] =
            new Thread({
                pinCurrentThread(
                    thiefIndex < OwnerCpu
                        ? thiefIndex
                        : thiefIndex + 1);

                atomicFetchAdd!(
                    MemoryOrder.rel)(
                        readyCount,
                        1);

                TaskRef[BatchSize]
                    batch;

                size_t localStolen;
                size_t localSpillExecuted;

                size_t localQueueClaims;
                size_t localSpillClaims;

                ulong localSum;
                ulong localXor;
                ulong localWork;

                while (
                    !atomicLoad!(
                        MemoryOrder.acq)(
                            start))
                {
                    Thread.yield();
                }

                for (;;)
                {
                    const taken =
                        queue.stealBatch(
                            batch[]);

                    if (taken != 0)
                    {
                        ++localQueueClaims;

                        foreach (
                            task;
                            batch[0 .. taken])
                        {
                            localSum +=
                                task.value;

                            localXor ^=
                                task.value;

                            localWork ^=
                                doWork(
                                    task.value,
                                    rounds);

                            ++localStolen;
                        }

                        continue;
                    }

                    if (
                        policy ==
                        OverflowPolicy.globalSpill)
                    {
                        const spillTaken =
                            spill.popBatch(
                                batch[]);

                        if (
                            spillTaken != 0)
                        {
                            ++localSpillClaims;

                            foreach (
                                task;
                                batch[
                                    0 ..
                                    spillTaken])
                            {
                                localSum +=
                                    task.value;

                                localXor ^=
                                    task.value;

                                localWork ^=
                                    doWork(
                                        task.value,
                                        rounds);

                                ++localSpillExecuted;
                            }

                            continue;
                        }
                    }

                    if (
                        atomicLoad!(
                            MemoryOrder.acq)(
                                producerDone) &&
                        queue.emptySnapshot() &&
                        (
                            policy !=
                                OverflowPolicy.globalSpill ||
                            spill.empty()
                        ))
                    {
                        break;
                    }

                    Thread.yield();
                }

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        stolenExecuted,
                        localStolen);

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        spillExecuted,
                        localSpillExecuted);

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        localClaims,
                        localQueueClaims);

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        spillClaims,
                        localSpillClaims);

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        stolenSum,
                        localSum);

                atomicOp!"^="(
                    stolenXor,
                    localXor);

                atomicOp!"^="(
                    stolenWork,
                    localWork);
            });

        thieves[thiefIndex].start();
    }

    pinCurrentThread(
        OwnerCpu);

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                readyCount) !=
        Thieves)
    {
        Thread.yield();
    }

    RunResult result;

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (i; 0 .. Tasks)
    {
        const task =
            TaskRef(
                cast(ulong) i + 1);

        if (queue.tryPush(task))
            continue;

        ++result.fullEvents;

        final switch (policy)
        {
            case OverflowPolicy.retry:
            {
                do
                {
                    ++result.retryAttempts;
                    Thread.yield();
                }
                while (
                    !queue.tryPush(
                        task));

                break;
            }

            case OverflowPolicy.executeInline:
            {
                ++result.inlineExecuted;

                result.valueSum +=
                    task.value;

                result.valueXor ^=
                    task.value;

                result.workChecksum ^=
                    doWork(
                        task.value,
                        rounds);

                break;
            }

            case OverflowPolicy.globalSpill:
            {
                if (!spill.push(task))
                {
                    throw new Exception(
                        "spill capacity exceeded");
                }

                ++result.spillPushes;

                break;
            }
        }
    }

    atomicStore!(
        MemoryOrder.rel)(
            producerDone,
            true);

    /*
     * As in P12a/P12b the producer may drain its local owner queue after
     * production completes.
     *
     * It does not execute overflow tasks merely because the local queue was
     * full. Spill tasks remain worker-consumed.
     */
    for (;;)
    {
        const popped =
            queue.pop();

        if (popped.found)
        {
            ++result.ownerExecuted;

            result.valueSum +=
                popped.value.value;

            result.valueXor ^=
                popped.value.value;

            result.workChecksum ^=
                doWork(
                    popped.value.value,
                    rounds);

            continue;
        }

        if (queue.emptySnapshot())
            break;
    }

    foreach (thief; thieves)
        thief.join();

    sw.stop();

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.stolenExecuted =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenExecuted);

    result.spillExecuted =
        atomicLoad!(
            MemoryOrder.acq)(
                spillExecuted);

    result.localClaims =
        atomicLoad!(
            MemoryOrder.acq)(
                localClaims);

    result.spillClaims =
        atomicLoad!(
            MemoryOrder.acq)(
                spillClaims);

    result.valueSum +=
        atomicLoad!(
            MemoryOrder.acq)(
                stolenSum);

    result.valueXor ^=
        atomicLoad!(
            MemoryOrder.acq)(
                stolenXor);

    result.workChecksum ^=
        atomicLoad!(
            MemoryOrder.acq)(
                stolenWork);

    const totalExecuted =
        result.ownerExecuted +
        result.stolenExecuted +
        result.inlineExecuted +
        result.spillExecuted;

    if (
        totalExecuted !=
        Tasks)
    {
        throw new Exception(
            "execution count mismatch");
    }

    if (
        policy ==
            OverflowPolicy.globalSpill &&
        result.inlineExecuted != 0)
    {
        throw new Exception(
            "spill policy executed overflow inline");
    }

    if (
        result.spillExecuted !=
        result.spillPushes)
    {
        throw new Exception(
            "spill accounting mismatch");
    }

    const n =
        cast(ulong) Tasks;

    const expectedSum =
        n * (n + 1) / 2;

    if (
        result.valueSum !=
        expectedSum)
    {
        throw new Exception(
            "value sum mismatch");
    }

    ulong expectedXor;

    final switch (n & 3)
    {
        case 0:
            expectedXor = n;
            break;

        case 1:
            expectedXor = 1;
            break;

        case 2:
            expectedXor = n + 1;
            break;

        case 3:
            expectedXor = 0;
            break;
    }

    if (
        result.valueXor !=
        expectedXor)
    {
        throw new Exception(
            "value xor mismatch");
    }

    if (
        result.workChecksum !=
        expectedWorkChecksum(
            rounds))
    {
        throw new Exception(
            "work checksum mismatch");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "local queue not empty");

    if (!spill.empty())
        throw new Exception(
            "spill queue not empty");

    return result;
}

private Stats calculateStats(
    ulong[] values)
{
    values.sort();

    return Stats(
        cast(double)
            values[
                values.length / 2] /
            Tasks,
        cast(double)
            values[
                (values.length - 1) *
                10 / 100] /
            Tasks,
        cast(double)
            values[
                (values.length - 1) *
                90 / 100] /
            Tasks);
}

private string policyName(
    OverflowPolicy policy)
{
    final switch (policy)
    {
        case OverflowPolicy.retry:
            return "retry";

        case OverflowPolicy.executeInline:
            return "inline";

        case OverflowPolicy.globalSpill:
            return "spill";
    }
}

private void benchmark(
    OverflowPolicy policy,
    size_t rounds)
{
    foreach (_; 0 .. Warmups)
    {
        run(
            policy,
            rounds);
    }

    ulong[Samples] times;

    size_t totalOwner;
    size_t totalStolen;
    size_t totalInline;
    size_t totalSpillExecuted;

    size_t totalFull;
    size_t totalRetries;

    size_t totalLocalClaims;
    size_t totalSpillPushes;
    size_t totalSpillClaims;

    foreach (i; 0 .. Samples)
    {
        const result =
            run(
                policy,
                rounds);

        times[i] =
            result.elapsedNs;

        totalOwner +=
            result.ownerExecuted;

        totalStolen +=
            result.stolenExecuted;

        totalInline +=
            result.inlineExecuted;

        totalSpillExecuted +=
            result.spillExecuted;

        totalFull +=
            result.fullEvents;

        totalRetries +=
            result.retryAttempts;

        totalLocalClaims +=
            result.localClaims;

        totalSpillPushes +=
            result.spillPushes;

        totalSpillClaims +=
            result.spillClaims;
    }

    const s =
        calculateStats(
            times[]);

    const totalTasks =
        Tasks * Samples;

    const double fullPerTask =
        cast(double)
            totalFull /
        totalTasks;

    const double inlineShare =
        cast(double)
            totalInline *
        100.0 /
        totalTasks;

    const double spillShare =
        cast(double)
            totalSpillExecuted *
        100.0 /
        totalTasks;

    const double localPerClaim =
        totalLocalClaims != 0
            ? cast(double)
                totalStolen /
                totalLocalClaims
            : 0.0;

    const double spillPerClaim =
        totalSpillClaims != 0
            ? cast(double)
                totalSpillExecuted /
                totalSpillClaims
            : 0.0;

    writefln(
        "%-8s work=%2s median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f",
        policyName(policy),
        rounds,
        s.median,
        s.p10,
        s.p90);

    writefln(
        "         owner=%s stolen=%s "
        ~ "inline=%s spill=%s",
        totalOwner,
        totalStolen,
        totalInline,
        totalSpillExecuted);

    writefln(
        "         fullEvents=%s full/task=%.6f "
        ~ "retries=%s",
        totalFull,
        fullPerTask,
        totalRetries);

    writefln(
        "         inlineShare=%.3f%% "
        ~ "spillShare=%.3f%%",
        inlineShare,
        spillShare);

    writefln(
        "         localClaims=%s local/claim=%.3f",
        totalLocalClaims,
        localPerClaim);

    writefln(
        "         spillPushes=%s spillClaims=%s "
        ~ "spill/claim=%.3f",
        totalSpillPushes,
        totalSpillClaims,
        spillPerClaim);
}

void main()
{
    writeln(
        "R0.1 P12c global spill baseline");

    writefln(
        "capacity=%s tasks=%s thieves=%s "
        ~ "batch=%s warmups=%s samples=%s",
        Capacity,
        Tasks,
        Thieves,
        BatchSize,
        Warmups,
        Samples);

    foreach (
        rounds;
        [0, 16, 64])
    {
        benchmark(
            OverflowPolicy.retry,
            rounds);

        benchmark(
            OverflowPolicy.executeInline,
            rounds);

        benchmark(
            OverflowPolicy.globalSpill,
            rounds);
    }

    writeln(
        "R0.1 P12c PASS");
}
