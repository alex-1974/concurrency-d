module app;

import core.atomic :
    MemoryOrder,
    atomicLoad;

import std.algorithm.sorting :
    sort;

import std.datetime.stopwatch :
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t RecordCount =
    1 << 20;

enum size_t Warmups = 3;
enum size_t Samples = 11;

struct TaskHeader
{
    alias ExecuteFn =
        ulong function(
            shared(TaskHeader)*,
            size_t)
            @safe @nogc nothrow;

    ExecuteFn execute;
}

alias ExecuteFn =
    TaskHeader.ExecuteFn;

struct TaskRef
{
    shared(TaskHeader)* ptr;
}

struct MinimalRecord
{
    TaskHeader header;
    ulong payload;
}

struct StateRecord
{
    TaskHeader header;
    shared uint state;
    uint reserved;
    ulong payload;
}

struct ScopeRecord
{
    TaskHeader header;
    shared uint state;
    uint reserved;
    shared(void)* scopeOwner;
    ulong payload;
}

struct Speculative64Record
{
    TaskHeader header;
    shared uint state;
    uint flags;
    shared(void)* scopeOwner;
    ulong resultSlot;
    ulong cancellation;
    ulong reserved0;
    ulong reserved1;
    ulong payload;
}

struct Distribution
{
    double median;
    double p10;
    double p90;
}

private __gshared ulong observableChecksum;

private ulong work(
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

private ulong executeMinimal(
    shared(TaskHeader)* header,
    size_t rounds)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared(MinimalRecord)*)
            header;

    return work(
        atomicLoad!(
            MemoryOrder.raw)(
                record.payload),
        rounds);
}

private ulong executeState(
    shared(TaskHeader)* header,
    size_t rounds)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared(StateRecord)*)
            header;

    return work(
        atomicLoad!(
            MemoryOrder.raw)(
                record.payload),
        rounds);
}

private ulong executeScope(
    shared(TaskHeader)* header,
    size_t rounds)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared(ScopeRecord)*)
            header;

    return work(
        atomicLoad!(
            MemoryOrder.raw)(
                record.payload),
        rounds);
}

private ulong executeSpeculative64(
    shared(TaskHeader)* header,
    size_t rounds)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared(Speculative64Record)*)
            header;

    return work(
        atomicLoad!(
            MemoryOrder.raw)(
                record.payload),
        rounds);
}

private ulong dispatch(
    TaskRef task,
    size_t rounds)
    @safe @nogc nothrow
{
    const execute =
        atomicLoad!(
            MemoryOrder.raw)(
                task.ptr.execute);

    return execute(
        task.ptr,
        rounds);
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

private ulong run(
    TaskRef[] refs,
    size_t rounds)
{
    ulong checksum;

    foreach (task; refs)
    {
        checksum ^=
            dispatch(
                task,
                rounds);
    }

    return checksum;
}

private void benchmark(
    string recordName,
    string accessName,
    TaskRef[] refs,
    size_t rounds)
{
    foreach (_; 0 .. Warmups)
    {
        observableChecksum ^=
            run(
                refs,
                rounds);
    }

    ulong[Samples] elapsed;

    foreach (sample; 0 .. Samples)
    {
        StopWatch sw;
        sw.start();

        const checksum =
            run(
                refs,
                rounds);

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

    writefln(
        "%-14s %-10s rounds=%2s "
        ~ "median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f",
        recordName,
        accessName,
        rounds,
        d.median / RecordCount,
        d.p10 / RecordCount,
        d.p90 / RecordCount);
}

private size_t shuffledIndex(
    size_t index)
    @safe @nogc nothrow
{
    enum ulong Multiplier =
        0x9e37_79b9_7f4a_7c15UL;

    return
        cast(size_t)(
            (
                cast(ulong) index *
                Multiplier
            ) &
            (RecordCount - 1));
}

private void fillRefs(
    Record)(
    Record[] records,
    TaskRef[] sequential,
    TaskRef[] shuffled,
    ExecuteFn execute)
{
    foreach (i; 0 .. RecordCount)
    {
        records[i].header.execute =
            execute;

        records[i].payload =
            cast(ulong) i + 1;

        sequential[i] =
            TaskRef(
                cast(shared(TaskHeader)*)
                    &records[i].header);

        const shuffledRecord =
            shuffledIndex(i);

        shuffled[i] =
            TaskRef(
                cast(shared(TaskHeader)*)
                    &records[
                        shuffledRecord]
                    .header);
    }
}

private void qualify(
    Record)(
    string name,
    ExecuteFn execute)
{
    auto records =
        new Record[RecordCount];

    auto sequential =
        new TaskRef[RecordCount];

    auto shuffled =
        new TaskRef[RecordCount];

    fillRefs(
        records,
        sequential,
        shuffled,
        execute);

    foreach (
        rounds;
        [size_t(0), size_t(8)])
    {
        benchmark(
            name,
            "sequential",
            sequential,
            rounds);

        benchmark(
            name,
            "shuffled",
            shuffled,
            rounds);
    }
}

void main()
{
    writeln(
        "R0.2 P03 TaskRecord locality");

    writefln(
        "records=%s warmups=%s samples=%s",
        RecordCount,
        Warmups,
        Samples);

    writefln(
        "TaskHeader size=%s align=%s TaskRef=%s",
        TaskHeader.sizeof,
        TaskHeader.alignof,
        TaskRef.sizeof);

    writefln(
        "MinimalRecord=%s StateRecord=%s ScopeRecord=%s Speculative64Record=%s",
        MinimalRecord.sizeof,
        StateRecord.sizeof,
        ScopeRecord.sizeof,
        Speculative64Record.sizeof);

    static assert(
        TaskHeader.sizeof == 8);

    static assert(
        TaskRef.sizeof == 8);

    static assert(
        MinimalRecord.sizeof == 16);

    static assert(
        StateRecord.sizeof == 24);

    static assert(
        ScopeRecord.sizeof == 32);

    static assert(
        Speculative64Record.sizeof == 64);

    qualify!MinimalRecord(
        "minimal-16",
        &executeMinimal);

    qualify!StateRecord(
        "state-24",
        &executeState);

    qualify!ScopeRecord(
        "scope-32",
        &executeScope);

    qualify!Speculative64Record(
        "speculative-64",
        &executeSpeculative64);

    writefln(
        "observable=%s",
        observableChecksum);

    writeln(
        "R0.2 P03 PASS");
}
