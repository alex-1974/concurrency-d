module app;

import containers :
    WorkStealingDeque;

import std.algorithm.sorting :
    sort;

import std.datetime.stopwatch :
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t Capacity = 4096;
enum size_t Cycles = 64;
enum size_t Warmups = 2;
enum size_t Samples = 9;

enum Pattern
{
    homogeneous,
    mixed4
}

enum Representation
{
    pointerOnly,
    pointerExecute,
    recordTag
}

alias ExecuteFn =
    ulong function(
        ulong,
        size_t)
        @safe @nogc nothrow;

struct TaskRecord
{
    ExecuteFn execute;
    ulong payload;
    ubyte kind;
}

struct PointerOnlyRef
{
    shared(TaskRecord)* ptr;
}

struct PointerExecuteRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}

struct Distribution
{
    double median;
    double p10;
    double p90;
}

private __gshared ulong observableChecksum;

private ulong workA(
    ulong x,
    size_t rounds)
    @safe @nogc nothrow
{
    x +=
        0x9e37_79b9_7f4a_7c15UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x >> 12;
        x *=
            0x2545_f491_4f6c_dd1dUL;
        x +=
            cast(ulong) i + 1;
    }

    return x;
}

private ulong workB(
    ulong x,
    size_t rounds)
    @safe @nogc nothrow
{
    x ^=
        0xbf58_476d_1ce4_e5b9UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x << 13;
        x *=
            0x94d0_49bb_1331_11ebUL;
        x +=
            cast(ulong) i + 3;
    }

    return x;
}

private ulong workC(
    ulong x,
    size_t rounds)
    @safe @nogc nothrow
{
    x +=
        0xd1b5_4a32_d192_ed03UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x >> 17;
        x *=
            0x9e37_79b9_7f4a_7c15UL;
        x +=
            cast(ulong) i + 5;
    }

    return x;
}

private ulong workD(
    ulong x,
    size_t rounds)
    @safe @nogc nothrow
{
    x ^=
        0x94d0_49bb_1331_11ebUL;

    foreach (i; 0 .. rounds)
    {
        x ^= x << 7;
        x *=
            0xbf58_476d_1ce4_e5b9UL;
        x +=
            cast(ulong) i + 7;
    }

    return x;
}

private ExecuteFn loadExecute(
    shared(TaskRecord)* ptr)
    @trusted @nogc nothrow
{
    return
        (cast(TaskRecord*) ptr)
        .execute;
}

private ulong loadPayload(
    shared(TaskRecord)* ptr)
    @trusted @nogc nothrow
{
    return
        (cast(TaskRecord*) ptr)
        .payload;
}

private ubyte loadKind(
    shared(TaskRecord)* ptr)
    @trusted @nogc nothrow
{
    return
        (cast(TaskRecord*) ptr)
        .kind;
}

private ulong dispatchPointerOnly(
    PointerOnlyRef task,
    size_t rounds)
    @safe @nogc nothrow
{
    const execute =
        loadExecute(
            task.ptr);

    return execute(
        loadPayload(
            task.ptr),
        rounds);
}

private ulong dispatchPointerExecute(
    PointerExecuteRef task,
    size_t rounds)
    @safe @nogc nothrow
{
    return task.execute(
        loadPayload(
            task.ptr),
        rounds);
}

private ulong dispatchRecordTag(
    PointerOnlyRef task,
    size_t rounds)
    @safe @nogc nothrow
{
    const payload =
        loadPayload(
            task.ptr);

    final switch (
        loadKind(
            task.ptr))
    {
        case 0:
            return workA(
                payload,
                rounds);

        case 1:
            return workB(
                payload,
                rounds);

        case 2:
            return workC(
                payload,
                rounds);

        case 3:
            return workD(
                payload,
                rounds);
    }
}

private ubyte kindFor(
    size_t index,
    Pattern pattern)
    @safe @nogc nothrow
{
    final switch (pattern)
    {
        case Pattern.homogeneous:
            return 0;

        case Pattern.mixed4:
            const mixed =
                (
                    cast(ulong) index *
                    0x9e37_79b9_7f4a_7c15UL
                ) ^
                (
                    cast(ulong) index >>
                    3
                );

            return
                cast(ubyte)
                    (mixed & 3);
    }
}

private ExecuteFn executeFor(
    ubyte kind)
    @safe @nogc nothrow
{
    final switch (kind)
    {
        case 0:
            return &workA;

        case 1:
            return &workB;

        case 2:
            return &workC;

        case 3:
            return &workD;
    }
}

private string patternName(
    Pattern pattern)
    @safe @nogc nothrow
{
    final switch (pattern)
    {
        case Pattern.homogeneous:
            return "homogeneous";

        case Pattern.mixed4:
            return "mixed4";
    }
}

private string representationName(
    Representation representation)
    @safe @nogc nothrow
{
    final switch (representation)
    {
        case Representation.pointerOnly:
            return "pointer-only";

        case Representation.pointerExecute:
            return "pointer+execute";

        case Representation.recordTag:
            return "record-tag";
    }
}

private Distribution distribution(
    ulong[] values)
{
    values.sort();

    return Distribution(
        cast(double)
            values[
                values.length / 2],
        cast(double)
            values[
                (values.length - 1) *
                10 / 100],
        cast(double)
            values[
                (values.length - 1) *
                90 / 100]);
}

private ulong runPointerOnly(
    PointerOnlyRef[] tasks,
    size_t rounds)
{
    WorkStealingDeque!(
        PointerOnlyRef,
        Capacity) queue;

    ulong checksum;

    foreach (_; 0 .. Cycles)
    {
        foreach (task; tasks)
        {
            if (!queue.tryPush(task))
                assert(0);
        }

        foreach (_task; 0 .. Capacity)
        {
            const taken =
                queue.pop();

            if (!taken.found)
                assert(0);

            checksum ^=
                dispatchPointerOnly(
                    taken.value,
                    rounds);
        }

        assert(
            !queue.pop().found);
    }

    return checksum;
}

private ulong runPointerExecute(
    PointerExecuteRef[] tasks,
    size_t rounds)
{
    WorkStealingDeque!(
        PointerExecuteRef,
        Capacity) queue;

    ulong checksum;

    foreach (_; 0 .. Cycles)
    {
        foreach (task; tasks)
        {
            if (!queue.tryPush(task))
                assert(0);
        }

        foreach (_task; 0 .. Capacity)
        {
            const taken =
                queue.pop();

            if (!taken.found)
                assert(0);

            checksum ^=
                dispatchPointerExecute(
                    taken.value,
                    rounds);
        }

        assert(
            !queue.pop().found);
    }

    return checksum;
}

private ulong runRecordTag(
    PointerOnlyRef[] tasks,
    size_t rounds)
{
    WorkStealingDeque!(
        PointerOnlyRef,
        Capacity) queue;

    ulong checksum;

    foreach (_; 0 .. Cycles)
    {
        foreach (task; tasks)
        {
            if (!queue.tryPush(task))
                assert(0);
        }

        foreach (_task; 0 .. Capacity)
        {
            const taken =
                queue.pop();

            if (!taken.found)
                assert(0);

            checksum ^=
                dispatchRecordTag(
                    taken.value,
                    rounds);
        }

        assert(
            !queue.pop().found);
    }

    return checksum;
}

private void benchmark(
    Representation representation,
    Pattern pattern,
    size_t rounds,
    PointerOnlyRef[] pointerOnly,
    PointerExecuteRef[] pointerExecute)
{
    foreach (_; 0 .. Warmups)
    {
        final switch (representation)
        {
            case Representation.pointerOnly:
                observableChecksum ^=
                    runPointerOnly(
                        pointerOnly,
                        rounds);
                break;

            case Representation.pointerExecute:
                observableChecksum ^=
                    runPointerExecute(
                        pointerExecute,
                        rounds);
                break;

            case Representation.recordTag:
                observableChecksum ^=
                    runRecordTag(
                        pointerOnly,
                        rounds);
                break;
        }
    }

    ulong[Samples] elapsed;

    foreach (sample; 0 .. Samples)
    {
        StopWatch sw;
        sw.start();

        ulong checksum;

        final switch (representation)
        {
            case Representation.pointerOnly:
                checksum =
                    runPointerOnly(
                        pointerOnly,
                        rounds);
                break;

            case Representation.pointerExecute:
                checksum =
                    runPointerExecute(
                        pointerExecute,
                        rounds);
                break;

            case Representation.recordTag:
                checksum =
                    runRecordTag(
                        pointerOnly,
                        rounds);
                break;
        }

        sw.stop();

        observableChecksum ^=
            checksum;

        elapsed[sample] =
            cast(ulong)
                sw.peek.total!"nsecs";
    }

    const d =
        distribution(
            elapsed[]);

    enum size_t TasksPerSample =
        Capacity *
        Cycles;

    writefln(
        "%-15s %-11s rounds=%2s "
        ~ "median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f",
        representationName(
            representation),
        patternName(
            pattern),
        rounds,
        d.median / TasksPerSample,
        d.p10 / TasksPerSample,
        d.p90 / TasksPerSample);
}

void main()
{
    writeln(
        "R0.2 P02b queue+dispatch");

    writefln(
        "capacity=%s cycles=%s tasks/sample=%s "
        ~ "warmups=%s samples=%s",
        Capacity,
        Cycles,
        Capacity * Cycles,
        Warmups,
        Samples);

    TaskRecord[Capacity] records;
    PointerOnlyRef[Capacity] pointerOnly;
    PointerExecuteRef[Capacity] pointerExecute;

    foreach (
        pattern;
        [
            Pattern.homogeneous,
            Pattern.mixed4
        ])
    {
        foreach (i; 0 .. Capacity)
        {
            const kind =
                kindFor(
                    i,
                    pattern);

            records[i] =
                TaskRecord(
                    executeFor(kind),
                    cast(ulong) i + 1,
                    kind);

            auto ptr =
                cast(shared(TaskRecord)*)
                    &records[i];

            pointerOnly[i] =
                PointerOnlyRef(
                    ptr);

            pointerExecute[i] =
                PointerExecuteRef(
                    ptr,
                    executeFor(kind));
        }

        foreach (
            rounds;
            [size_t(0), size_t(16)])
        {
            benchmark(
                Representation.pointerOnly,
                pattern,
                rounds,
                pointerOnly[],
                pointerExecute[]);

            benchmark(
                Representation.pointerExecute,
                pattern,
                rounds,
                pointerOnly[],
                pointerExecute[]);

            benchmark(
                Representation.recordTag,
                pattern,
                rounds,
                pointerOnly[],
                pointerExecute[]);
        }
    }

    writefln(
        "observable=%s",
        observableChecksum);

    writeln(
        "R0.2 P02b PASS");
}
