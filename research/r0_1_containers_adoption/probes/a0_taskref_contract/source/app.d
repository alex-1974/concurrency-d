module app;

import containers :
    WorkStealingDeque,
    WorkStealingTakeResult;

import std.stdio :
    writeln;

struct TaskRecord
{
    ulong id;
}

struct TaskRef
{
    shared(TaskRecord)* ptr;
}

alias Queue =
    WorkStealingDeque!(
        TaskRef,
        8);

private shared TaskRecord[8]
    records;

private void qualifyTaskRef()
    @safe @nogc nothrow
{
    Queue queue;

    foreach (i; 0 .. 4)
    {
        records[i].id =
            cast(ulong) i + 1;

        const task =
            TaskRef(
                &records[i]);

        assert(
            queue.tryPush(
                task));
    }

    WorkStealingTakeResult!TaskRef
        stolen =
            queue.steal();

    assert(stolen.found);
    assert(
        stolen.value.ptr ==
        &records[0]);

    TaskRef[2] batch;

    const taken =
        queue.stealBatch(
            batch[]);

    assert(taken == 2);
    assert(
        batch[0].ptr ==
        &records[1]);
    assert(
        batch[1].ptr ==
        &records[2]);

    const owner =
        queue.pop();

    assert(owner.found);
    assert(
        owner.value.ptr ==
        &records[3]);

    assert(
        !queue.pop().found);
    assert(
        !queue.steal().found);
}

void main()
{
    qualifyTaskRef();

    writeln(
        "R0.1 adoption A0 PASS: containers-d TaskRef contract");
}
