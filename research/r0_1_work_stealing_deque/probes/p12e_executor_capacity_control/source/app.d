module app;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicStore;

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

enum size_t Tasks = 262_144;
enum size_t Warmups = 3;
enum size_t Samples = 15;

enum size_t OwnerCpu = 2;

struct Stats
{
    double median;
    double p10;
    double p90;
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
}

private ulong expectedChecksum(
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


private Thread makeWorker4Thread(
    size_t workerIndex,
    size_t cpu,
    size_t rounds,
    shared size_t* ready,
    shared bool* start,
    shared ulong* checksums)
{
    return new Thread({
        pinCurrentThread(
            cpu);

        atomicFetchAdd!(
            MemoryOrder.rel)(
                *ready,
                1);

        while (
            !atomicLoad!(
                MemoryOrder.acq)(
                    *start))
        {
            Thread.yield();
        }

        ulong checksum;

        for (
            size_t i = workerIndex;
            i < Tasks;
            i += 4)
        {
            checksum ^=
                doWork(
                    cast(ulong) i + 1,
                    rounds);
        }

        atomicStore!(
            MemoryOrder.rel)(
                checksums[workerIndex],
                checksum);
    });
}

private Thread makeOwner3WorkerThread(
    size_t workerIndex,
    size_t cpu,
    size_t rounds,
    shared size_t* ready,
    shared bool* start,
    shared ulong* checksums)
{
    return new Thread({
        pinCurrentThread(
            cpu);

        atomicFetchAdd!(
            MemoryOrder.rel)(
                *ready,
                1);

        while (
            !atomicLoad!(
                MemoryOrder.acq)(
                    *start))
        {
            Thread.yield();
        }

        ulong checksum;

        for (
            size_t i = workerIndex;
            i < Tasks;
            i += 4)
        {
            checksum ^=
                doWork(
                    cast(ulong) i + 1,
                    rounds);
        }

        atomicStore!(
            MemoryOrder.rel)(
                checksums[workerIndex],
                checksum);
    });
}

private ulong runWorker4(
    size_t rounds)
{
    immutable size_t[4] cpus =
        [0, 1, 3, 4];

    shared size_t ready;
    shared bool start;

    shared ulong[4] checksums;

    Thread[4] threads;

    foreach (worker; 0 .. 4)
    {
        threads[worker] =
            makeWorker4Thread(
                worker,
                cpus[worker],
                rounds,
                &ready,
                &start,
                checksums.ptr);

        threads[worker].start();
    }

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                ready) != 4)
    {
        Thread.yield();
    }

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (thread; threads)
        thread.join();

    sw.stop();

    ulong checksum;

    foreach (i; 0 .. 4)
    {
        checksum ^=
            atomicLoad!(
                MemoryOrder.acq)(
                    checksums[i]);
    }

    if (
        checksum !=
        expectedChecksum(rounds))
    {
        throw new Exception(
            "worker4 checksum mismatch");
    }

    return
        cast(ulong)
            sw.peek.total!"nsecs";
}

private ulong runOwner3(
    size_t rounds)
{
    immutable size_t[3] cpus =
        [0, 1, 3];

    shared size_t ready;
    shared bool start;

    shared ulong[3] checksums;

    Thread[3] threads;

    foreach (worker; 0 .. 3)
    {
        threads[worker] =
            makeOwner3WorkerThread(
                worker,
                cpus[worker],
                rounds,
                &ready,
                &start,
                checksums.ptr);

        threads[worker].start();
    }

    pinCurrentThread(
        OwnerCpu);

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                ready) != 3)
    {
        Thread.yield();
    }

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    ulong ownerChecksum;

    for (
        size_t i = 3;
        i < Tasks;
        i += 4)
    {
        ownerChecksum ^=
            doWork(
                cast(ulong) i + 1,
                rounds);
    }

    foreach (thread; threads)
        thread.join();

    sw.stop();

    ulong checksum =
        ownerChecksum;

    foreach (i; 0 .. 3)
    {
        checksum ^=
            atomicLoad!(
                MemoryOrder.acq)(
                    checksums[i]);
    }

    if (
        checksum !=
        expectedChecksum(rounds))
    {
        throw new Exception(
            "owner3 checksum mismatch");
    }

    return
        cast(ulong)
            sw.peek.total!"nsecs";
}

private Stats stats(
    ulong[] values)
{
    values.sort();

    return Stats(
        cast(double)
            values[values.length / 2] /
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

private void benchmark(
    size_t rounds)
{
    foreach (_; 0 .. Warmups)
    {
        runWorker4(rounds);
        runOwner3(rounds);
    }

    ulong[Samples] worker4;
    ulong[Samples] owner3;

    foreach (i; 0 .. Samples)
    {
        worker4[i] =
            runWorker4(rounds);

        owner3[i] =
            runOwner3(rounds);
    }

    const a =
        stats(worker4[]);

    const b =
        stats(owner3[]);

    writefln(
        "worker4 work=%2s median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f",
        rounds,
        a.median,
        a.p10,
        a.p90);

    writefln(
        "owner+3 work=%2s median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f",
        rounds,
        b.median,
        b.p10,
        b.p90);

    writefln(
        "         owner3/worker4 = %.3fx",
        b.median /
            a.median);
}

void main()
{
    writeln(
        "R0.1 P12e executor capacity control");

    writefln(
        "tasks=%s warmups=%s samples=%s",
        Tasks,
        Warmups,
        Samples);

    foreach (rounds; [16, 64])
        benchmark(rounds);

    writeln(
        "R0.1 P12e PASS");
}
