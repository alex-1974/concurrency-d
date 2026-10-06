module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import std.stdio :
    writefln,
    writeln;

import std.traits :
    hasElaborateAssign,
    hasElaborateCopyConstructor,
    hasElaborateDestructor;

enum size_t LogSize = 3;

struct Handle64
{
    ulong value;
}

struct Pair128
{
    ulong first;
    ulong second;
}

struct TaskRef128
{
    void* object;
    void* entry;
}

struct PostblitValue
{
    ulong value;

    this(this)
    {
    }
}

struct DestructorValue
{
    ulong value;

    ~this()
    {
    }
}

class GcObject
{
    ulong value;
}

template QueueOperationsCompile(T)
{
    enum bool QueueOperationsCompile =
        __traits(
            compiles,
            {
                alias Q =
                    MarkedTopBatchBoundedWorkStealingDeque!(
                        T,
                        LogSize);

                Q queue;

                T value =
                    T.init;

                T[4] batch;

                bool pushed =
                    queue.tryPush(
                        value);

                auto popped =
                    queue.pop();

                auto stolen =
                    queue.steal();

                size_t count =
                    queue.stealBatch(
                        batch[]);

                bool sink =
                    pushed ||
                    popped.found ||
                    stolen.found ||
                    count != 0;

                if (sink)
                {
                }
            }
        );
}

private void report(T)(
    string name)
{
    writefln(
        "%-18s size=%2s compile=%-5s "
        ~ "elaborateCopy=%-5s elaborateAssign=%-5s destructor=%-5s",
        name,
        T.sizeof,
        QueueOperationsCompile!T,
        hasElaborateCopyConstructor!T,
        hasElaborateAssign!T,
        hasElaborateDestructor!T);
}

private void pointerRuntimeProbe()
{
    static if (
        QueueOperationsCompile!(ulong*))
    {
        alias Q =
            MarkedTopBatchBoundedWorkStealingDeque!(
                ulong*,
                LogSize);

        auto queue =
            new Q;

        ulong a = 11;
        ulong b = 22;
        ulong c = 33;

        if (!queue.tryPush(&a))
            throw new Exception(
                "pointer push a failed");

        if (!queue.tryPush(&b))
            throw new Exception(
                "pointer push b failed");

        if (!queue.tryPush(&c))
            throw new Exception(
                "pointer push c failed");

        const popped =
            queue.pop();

        if (
            !popped.found ||
            popped.value !is &c)
        {
            throw new Exception(
                "pointer pop identity mismatch");
        }

        const stolen =
            queue.steal();

        if (
            !stolen.found ||
            stolen.value !is &a)
        {
            throw new Exception(
                "pointer steal identity mismatch");
        }

        ulong*[2] output;

        const taken =
            queue.stealBatch(
                output[]);

        if (
            taken != 1 ||
            output[0] !is &b)
        {
            throw new Exception(
                "pointer batch identity mismatch");
        }

        if (!queue.emptySnapshot())
            throw new Exception(
                "pointer queue not empty");

        writeln(
            "pointer runtime identity PASS");
    }
    else
    {
        writeln(
            "pointer runtime identity SKIP");
    }
}

void main()
{
    writeln(
        "R0.1 P10a element capability matrix");

    report!ulong(
        "ulong");

    report!(ulong*)(
        "ulong*");

    report!Handle64(
        "Handle64");

    report!Pair128(
        "Pair128");

    report!TaskRef128(
        "TaskRef128");

    report!GcObject(
        "GcObject");

    report!PostblitValue(
        "PostblitValue");

    report!DestructorValue(
        "DestructorValue");

    static assert(
        QueueOperationsCompile!ulong,
        "existing ulong control must compile");

    pointerRuntimeProbe();

    writeln(
        "R0.1 P10a PASS");
}
