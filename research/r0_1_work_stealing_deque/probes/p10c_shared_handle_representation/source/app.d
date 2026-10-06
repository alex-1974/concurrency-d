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

struct OpaqueHandle
{
    ulong value;
}

struct SharedPtrHandle
{
    shared(void)* ptr;
}

struct Pair128
{
    ulong first;
    ulong second;
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
        "%-22s size=%2s compile=%-5s "
        ~ "copy=%-5s assign=%-5s destructor=%-5s",
        name,
        T.sizeof,
        QueueOperationsCompile!T,
        hasElaborateCopyConstructor!T,
        hasElaborateAssign!T,
        hasElaborateDestructor!T);
}

private void sharedPointerRuntime()
{
    static if (
        QueueOperationsCompile!(
            shared(ulong)*))
    {
        alias Q =
            MarkedTopBatchBoundedWorkStealingDeque!(
                shared(ulong)*,
                LogSize);

        auto queue =
            new Q;

        shared ulong a = 11;
        shared ulong b = 22;
        shared ulong c = 33;

        auto pa = &a;
        auto pb = &b;
        auto pc = &c;

        if (!queue.tryPush(pa))
            throw new Exception(
                "shared pointer push a failed");

        if (!queue.tryPush(pb))
            throw new Exception(
                "shared pointer push b failed");

        if (!queue.tryPush(pc))
            throw new Exception(
                "shared pointer push c failed");

        const popped =
            queue.pop();

        if (
            !popped.found ||
            popped.value !is pc)
        {
            throw new Exception(
                "shared pointer pop identity mismatch");
        }

        const stolen =
            queue.steal();

        if (
            !stolen.found ||
            stolen.value !is pa)
        {
            throw new Exception(
                "shared pointer steal identity mismatch");
        }

        shared(ulong)*[2] output;

        const taken =
            queue.stealBatch(
                output[]);

        if (
            taken != 1 ||
            output[0] !is pb)
        {
            throw new Exception(
                "shared pointer batch identity mismatch");
        }

        if (!queue.emptySnapshot())
            throw new Exception(
                "shared pointer queue not empty");

        writeln(
            "shared pointer runtime identity PASS");
    }
    else
    {
        writeln(
            "shared pointer runtime identity SKIP");
    }
}

private void sharedHandleRuntime()
{
    static if (
        QueueOperationsCompile!(
            SharedPtrHandle))
    {
        alias Q =
            MarkedTopBatchBoundedWorkStealingDeque!(
                SharedPtrHandle,
                LogSize);

        auto queue =
            new Q;

        shared ulong a = 101;
        shared ulong b = 202;
        shared ulong c = 303;

        SharedPtrHandle ha =
            SharedPtrHandle(
                cast(shared(void)*) &a);

        SharedPtrHandle hb =
            SharedPtrHandle(
                cast(shared(void)*) &b);

        SharedPtrHandle hc =
            SharedPtrHandle(
                cast(shared(void)*) &c);

        if (!queue.tryPush(ha))
            throw new Exception(
                "shared handle push a failed");

        if (!queue.tryPush(hb))
            throw new Exception(
                "shared handle push b failed");

        if (!queue.tryPush(hc))
            throw new Exception(
                "shared handle push c failed");

        const popped =
            queue.pop();

        if (
            !popped.found ||
            popped.value.ptr !is hc.ptr)
        {
            throw new Exception(
                "shared handle pop identity mismatch");
        }

        const stolen =
            queue.steal();

        if (
            !stolen.found ||
            stolen.value.ptr !is ha.ptr)
        {
            throw new Exception(
                "shared handle steal identity mismatch");
        }

        SharedPtrHandle[2] output;

        const taken =
            queue.stealBatch(
                output[]);

        if (
            taken != 1 ||
            output[0].ptr !is hb.ptr)
        {
            throw new Exception(
                "shared handle batch identity mismatch");
        }

        if (!queue.emptySnapshot())
            throw new Exception(
                "shared handle queue not empty");

        writeln(
            "shared handle runtime identity PASS");
    }
    else
    {
        writeln(
            "shared handle runtime identity SKIP");
    }
}

void main()
{
    writeln(
        "R0.1 P10c shared handle representation");

    report!ulong(
        "ulong");

    report!OpaqueHandle(
        "OpaqueHandle");

    report!(ulong*)(
        "ulong*");

    report!(shared(ulong)*)(
        "shared(ulong)*");

    report!SharedPtrHandle(
        "SharedPtrHandle");

    report!Pair128(
        "Pair128");

    static assert(
        QueueOperationsCompile!OpaqueHandle,
        "opaque 64-bit handle must remain supported");

    sharedPointerRuntime();
    sharedHandleRuntime();

    writeln(
        "R0.1 P10c PASS");
}
