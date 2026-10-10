module app;

import containers :
    WorkStealingDeque;

import std.stdio :
    writefln,
    writeln;

struct TaskRecord
{
    ulong payload;
}

alias ExecuteFn =
    ulong function(
        ulong)
        @safe @nogc nothrow;

struct PointerExecuteRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}

align(16)
struct AlignedPointerExecuteRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}

private ulong execute(
    ulong value)
    @safe @nogc nothrow
{
    return value + 1;
}

private void qualifyAligned()
{
    alias Queue =
        WorkStealingDeque!(
            AlignedPointerExecuteRef,
            64);

    Queue queue;

    shared TaskRecord[64] records;

    foreach (round; 0 .. 10_000)
    {
        foreach (i; 0 .. 64)
        {
            records[i].payload =
                cast(ulong)
                    round * 64 +
                    i;

            AlignedPointerExecuteRef task =
                AlignedPointerExecuteRef(
                    &records[i],
                    &execute);

            if (!queue.tryPush(task))
                assert(0);
        }

        foreach (_; 0 .. 64)
        {
            auto task =
                queue.pop();

            if (!task.found)
                assert(0);

            if (task.value.execute is null)
                assert(0);

            const value =
                task.value.execute(
                    task.value.ptr.payload);

            if (value == 0)
                assert(0);
        }

        assert(!queue.pop().found);
    }
}

void main()
{
    alias UnalignedQueue =
        WorkStealingDeque!(
            PointerExecuteRef,
            64);

    alias AlignedQueue =
        WorkStealingDeque!(
            AlignedPointerExecuteRef,
            64);

    writeln(
        "R0.2 P02c atomic alignment diagnostic");

    writefln(
        "PointerExecuteRef size=%s align=%s queueAlign=%s",
        PointerExecuteRef.sizeof,
        PointerExecuteRef.alignof,
        UnalignedQueue.alignof);

    writefln(
        "AlignedPointerExecuteRef size=%s align=%s queueAlign=%s",
        AlignedPointerExecuteRef.sizeof,
        AlignedPointerExecuteRef.alignof,
        AlignedQueue.alignof);

    static assert(
        PointerExecuteRef.sizeof == 16);

    static assert(
        PointerExecuteRef.alignof == 8);

    static assert(
        AlignedPointerExecuteRef.sizeof == 16);

    static assert(
        AlignedPointerExecuteRef.alignof >= 16);

    qualifyAligned();

    writeln(
        "aligned 16-byte transport PASS");

    writeln(
        "R0.2 P02c PASS");
}
