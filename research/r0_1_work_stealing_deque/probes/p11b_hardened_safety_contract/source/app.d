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

/*
 * Persistent storage is intentional here.
 *
 * The P10 lifetime contract requires the referenced TaskRecord to outlive
 * every queued/in-flight TaskRef. A stack-local address would correctly be
 * rejected by @safe independently of the queue API.
 */
private shared ulong persistentRecord = 42;

template SafeApiCompiles()
{
    enum bool SafeApiCompiles =
        __traits(
            compiles,
            {
                @safe void probe(
                    ref Queue queue,
                    TaskRef value,
                    scope TaskRef[] batch)
                {
                    queue.tryPush(
                        value);

                    auto popped =
                        queue.pop();

                    auto stolen =
                        queue.steal();

                    queue.stealBatch(
                        batch);

                    const size =
                        queue.sizeSnapshot();

                    const empty =
                        queue.emptySnapshot();

                    if (
                        popped.found ||
                        stolen.found ||
                        size != 0 ||
                        empty)
                    {
                    }
                }
            }
        );
}

template CopyConstructionRejected()
{
    enum bool CopyConstructionRejected =
        !__traits(
            compiles,
            {
                Queue a;

                Queue b =
                    a;
            }
        );
}

template AssignmentRejected()
{
    enum bool AssignmentRejected =
        !__traits(
            compiles,
            {
                Queue a;
                Queue b;

                b = a;
            }
        );
}

template PassByValueRejected()
{
    enum bool PassByValueRejected =
        !__traits(
            compiles,
            {
                void consume(
                    Queue queue)
                {
                }

                Queue q;

                consume(q);
            }
        );
}

template ReturnFreshByValueAllowed()
{
    enum bool ReturnFreshByValueAllowed =
        __traits(
            compiles,
            {
                Queue makeQueue()
                @safe
                {
                    Queue queue;

                    return queue;
                }

                auto queue =
                    makeQueue();

                auto size =
                    queue.sizeSnapshot();

                if (size == size_t.max)
                {
                }
            }
        );
}

template SafeRoundTripCompiles()
{
    enum bool SafeRoundTripCompiles =
        __traits(
            compiles,
            {
                @safe void probe()
                {
                    Queue queue;

                    TaskRef refValue =
                        TaskRef(
                            &persistentRecord);

                    TaskRef[1] batch;

                    queue.tryPush(
                        refValue);

                    auto result =
                        queue.pop();

                    queue.tryPush(
                        refValue);

                    auto stolen =
                        queue.steal();

                    queue.tryPush(
                        refValue);

                    const count =
                        queue.stealBatch(
                            batch[]);

                    if (
                        result.found ||
                        stolen.found ||
                        count != 0)
                    {
                    }
                }
            }
        );
}

void main()
{
    writeln(
        "R0.1 P11b hardened safety contract");

    writefln(
        "complete API @safe       = %s",
        SafeApiCompiles!());

    writefln(
        "copy construction reject = %s",
        CopyConstructionRejected!());

    writefln(
        "assignment reject        = %s",
        AssignmentRejected!());

    writefln(
        "pass-by-value reject     = %s",
        PassByValueRejected!());

    writefln(
        "fresh return allowed     = %s",
        ReturnFreshByValueAllowed!());

    writefln(
        "@safe round trip         = %s",
        SafeRoundTripCompiles!());

    static assert(
        SafeApiCompiles!());

    static assert(
        CopyConstructionRejected!());

    static assert(
        AssignmentRejected!());

    static assert(
        PassByValueRejected!());

    static assert(
        ReturnFreshByValueAllowed!());

    static assert(
        SafeRoundTripCompiles!());

    writeln(
        "R0.1 P11b PASS");
}
