module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import std.stdio :
    writefln,
    writeln;

enum size_t LogSize = 3;

struct TaskRef
{
    shared(ulong)* ptr;
}

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        TaskRef,
        LogSize);

template SafePushCompiles()
{
    enum bool SafePushCompiles =
        __traits(
            compiles,
            {
                @safe void probe(
                    ref Queue queue,
                    TaskRef value)
                {
                    queue.tryPush(
                        value);
                }
            }
        );
}

template SafePopCompiles()
{
    enum bool SafePopCompiles =
        __traits(
            compiles,
            {
                @safe void probe(
                    ref Queue queue)
                {
                    auto result =
                        queue.pop();

                    if (result.found)
                    {
                        auto sink =
                            result.value;

                        if (sink.ptr is null)
                        {
                        }
                    }
                }
            }
        );
}

template SafeStealCompiles()
{
    enum bool SafeStealCompiles =
        __traits(
            compiles,
            {
                @safe void probe(
                    ref Queue queue)
                {
                    auto result =
                        queue.steal();

                    if (result.found)
                    {
                        auto sink =
                            result.value;

                        if (sink.ptr is null)
                        {
                        }
                    }
                }
            }
        );
}

template SafeStealBatchCompiles()
{
    enum bool SafeStealBatchCompiles =
        __traits(
            compiles,
            {
                @safe void probe(
                    ref Queue queue,
                    scope TaskRef[] output)
                {
                    queue.stealBatch(
                        output);
                }
            }
        );
}

template SafeSnapshotCompiles()
{
    enum bool SafeSnapshotCompiles =
        __traits(
            compiles,
            {
                @safe void probe(
                    ref const Queue queue)
                {
                    const size =
                        queue.sizeSnapshot();

                    const empty =
                        queue.emptySnapshot();

                    if (
                        size == 0 &&
                        empty)
                    {
                    }
                }
            }
        );
}

template ValueCopyCompiles()
{
    enum bool ValueCopyCompiles =
        __traits(
            compiles,
            {
                Queue a;

                Queue b =
                    a;

                auto sink =
                    b.sizeSnapshot();

                if (sink == size_t.max)
                {
                }
            }
        );
}

template AssignmentCompiles()
{
    enum bool AssignmentCompiles =
        __traits(
            compiles,
            {
                Queue a;
                Queue b;

                b = a;

                auto sink =
                    b.sizeSnapshot();

                if (sink == size_t.max)
                {
                }
            }
        );
}

template PassByValueCompiles()
{
    enum bool PassByValueCompiles =
        __traits(
            compiles,
            {
                void consume(
                    Queue queue)
                {
                    auto sink =
                        queue.sizeSnapshot();

                    if (sink == size_t.max)
                    {
                    }
                }

                Queue q;

                consume(q);
            }
        );
}

template ReturnByValueCompiles()
{
    enum bool ReturnByValueCompiles =
        __traits(
            compiles,
            {
                Queue makeQueue()
                {
                    Queue q;
                    return q;
                }

                auto q =
                    makeQueue();

                auto sink =
                    q.sizeSnapshot();

                if (sink == size_t.max)
                {
                }
            }
        );
}

template SafeTaskRefReadCompiles()
{
    enum bool SafeTaskRefReadCompiles =
        __traits(
            compiles,
            {
                @safe ulong readRef(
                    const TaskRef value)
                {
                    if (value.ptr is null)
                        return 0;

                    /*
                     * Merely carrying/inspecting the pointer identity is
                     * different from dereferencing shared task state.
                     */
                    return
                        cast(size_t)
                            value.ptr;
                }
            }
        );
}

template InvalidLogSizeZeroRejected()
{
    enum bool InvalidLogSizeZeroRejected =
        !__traits(
            compiles,
            MarkedTopBatchBoundedWorkStealingDeque!(
                TaskRef,
                0)
        );
}

template InvalidLogSizeHighRejected()
{
    enum bool InvalidLogSizeHighRejected =
        !__traits(
            compiles,
            MarkedTopBatchBoundedWorkStealingDeque!(
                TaskRef,
                62)
        );
}

void main()
{
    writeln(
        "R0.1 P11a safety boundary audit");

    writefln(
        "safe tryPush       = %s",
        SafePushCompiles!());

    writefln(
        "safe pop           = %s",
        SafePopCompiles!());

    writefln(
        "safe steal         = %s",
        SafeStealCompiles!());

    writefln(
        "safe stealBatch    = %s",
        SafeStealBatchCompiles!());

    writefln(
        "safe snapshots     = %s",
        SafeSnapshotCompiles!());

    writeln();

    writefln(
        "value copy         = %s",
        ValueCopyCompiles!());

    writefln(
        "assignment         = %s",
        AssignmentCompiles!());

    writefln(
        "pass by value      = %s",
        PassByValueCompiles!());

    writefln(
        "return by value    = %s",
        ReturnByValueCompiles!());

    writeln();

    writefln(
        "safe TaskRef identity inspection = %s",
        SafeTaskRefReadCompiles!());

    writefln(
        "LogSize=0 rejected  = %s",
        InvalidLogSizeZeroRejected!());

    writefln(
        "LogSize=62 rejected = %s",
        InvalidLogSizeHighRejected!());

    static assert(
        InvalidLogSizeZeroRejected!());

    static assert(
        InvalidLogSizeHighRejected!());

    writeln(
        "R0.1 P11a AUDIT COMPLETE");
}
