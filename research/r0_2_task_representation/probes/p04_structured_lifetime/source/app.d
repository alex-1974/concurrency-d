module app;

import containers :
    WorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicStore;

import core.thread :
    Thread;

import std.stdio :
    writeln;

enum size_t TaskCount = 1024;

struct TaskHeader
{
    alias ExecuteFn =
        void function(
            shared(TaskHeader)*)
            @safe @nogc nothrow;

    ExecuteFn execute;
}

alias ExecuteFn =
    TaskHeader.ExecuteFn;

struct TaskRef
{
    shared(TaskHeader)* ptr;
}

struct StackTaskRecord
{
    TaskHeader header;
    ulong payload;
    shared uint executions;
}

alias Queue =
    WorkStealingDeque!(
        TaskRef,
        TaskCount);

private shared StackTaskRecord[TaskCount]
    externalRecords;

/*
 * The header is the first field of every concrete task record. Recovering the
 * concrete type is the narrow type-erasure boundary. The generated thunk is
 * paired with the record type that installed it.
 */
private void executeStackTask(
    shared(TaskHeader)* header)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared(StackTaskRecord)*)
            header;

    const payload =
        atomicLoad!(
            MemoryOrder.raw)(
                record.payload);

    if (payload == 0)
        assert(0);

    atomicFetchAdd!(
        MemoryOrder.rel)(
            record.executions,
            1u);
}

private void dispatch(
    TaskRef task)
    @safe @nogc nothrow
{
    const execute =
        atomicLoad!(
            MemoryOrder.raw)(
                task.ptr.execute);

    execute(
        task.ptr);
}

private void qualifyRecords(
    scope shared StackTaskRecord[] records)
{
    assert(
        records.length ==
        TaskCount);

    Queue queue;

    foreach (i; 0 .. TaskCount)
    {
        records[i].header.execute =
            &executeStackTask;

        records[i].payload =
            cast(ulong) i + 1;

        records[i].executions = 0;

        TaskRef task =
            TaskRef(
                &records[i].header);

        if (!queue.tryPush(task))
            assert(0);
    }

    shared bool start;

    auto queuePtr =
        &queue;

    auto worker =
        new Thread({
            while (
                !atomicLoad!(
                    MemoryOrder.acq)(
                        start))
            {
                Thread.yield();
            }

            foreach (_; 0 .. TaskCount)
            {
                for (;;)
                {
                    auto task =
                        queuePtr.steal();

                    if (task.found)
                    {
                        dispatch(
                            task.value);

                        break;
                    }

                    Thread.yield();
                }
            }
        });

    worker.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    worker.join();

    foreach (i; 0 .. TaskCount)
    {
        assert(
            atomicLoad!(
                MemoryOrder.acq)(
                    records[i]
                    .executions) ==
            1);

        assert(
            atomicLoad!(
                MemoryOrder.raw)(
                    records[i]
                    .payload) ==
            cast(ulong) i + 1);
    }

    assert(
        !queue.pop().found);

    assert(
        !queue.steal().found);
}

private void qualifyStackResident()
{
    shared StackTaskRecord[TaskCount]
        records;

    /*
     * The owning function does not return until the worker has joined and
     * every queued/in-flight TaskRef has been consumed.
     */
    qualifyRecords(
        records[]);
}

private void qualifyExternalStable()
{
    qualifyRecords(
        externalRecords[]);
}

void main()
{
    writeln(
        "R0.2 P04 structured lifetime");

    static assert(
        TaskRef.sizeof == 8);

    static assert(
        TaskHeader.sizeof == 8);

    qualifyStackResident();

    writeln(
        "stack-resident join-before-return PASS");

    qualifyExternalStable();

    writeln(
        "externally-owned stable storage PASS");

    writeln(
        "R0.2 P04 PASS");
}
