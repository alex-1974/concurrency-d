/**
 * Internal typed-result experiment for issue #11.
 * Only atomic integral results and @safe @nogc nothrow function pointers
 * are admitted at this stage. No public API or ownership transfer.
 */
module concurrency.internal.typed_record;

import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : MemoryOrder, atomicLoad, atomicStore;

package(concurrency) struct ScalarTaskRecord(T)
if (is(T == int) || is(T == long) || is(T == ulong))
{
    TaskHeader header;
    alias WorkFn = T function(T) @safe @nogc nothrow;
    WorkFn work;
    T argument;
    T output;
    shared uint done;

    static void invoke(shared(TaskHeader)* header)
        @trusted @nogc nothrow
    {
        auto r = cast(shared(ScalarTaskRecord!T)*) header;
        const fn = atomicLoad!(MemoryOrder.raw)(r.work);
        const arg = atomicLoad!(MemoryOrder.raw)(r.argument);
        atomicStore!(MemoryOrder.raw)(r.output, fn(arg));
        atomicStore!(MemoryOrder.rel)(r.done, 1u);
    }
}

package(concurrency) TaskRef prepareScalar(T)(
    shared(ScalarTaskRecord!T)* record,
    ScalarTaskRecord!T.WorkFn work,
    T input)
{
    record.header.execute = &ScalarTaskRecord!T.invoke;
    record.work = work;
    record.argument = input;
    record.output = T.init;
    record.done = 0u;
    return TaskRef(&record.header);
}

version (unittest)
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
    import core.thread : Thread;

    private int square(int x) @safe @nogc nothrow
    {
        return x * x;
    }

    private long twice(long x) @safe @nogc nothrow
    {
        return x + x;
    }
}

unittest
{
    enum size_t N = 257;
    auto records = new shared ScalarTaskRecord!int[N];

    foreach (workers; [1, 4])
    {
        auto pool = new SubmissionWorkerPool(workers, 3);

        foreach (i; 0 .. N)
        {
            TaskRef task = prepareScalar(
                &records[i], &square, cast(int) i);

            for (;;)
            {
                auto status = pool.trySubmit(task);
                if (status == SubmissionResult.accepted)
                    break;

                assert(status == SubmissionResult.full);
                Thread.yield();
            }
        }

        pool.closeAndJoin();

        assert(pool.acceptedCount() == N);
        assert(pool.completedCount() == N);
        foreach (i; 0 .. N)
        {
            assert(atomicLoad!(MemoryOrder.acq)(
                records[i].done) == 1u);
            assert(atomicLoad!(MemoryOrder.raw)(
                records[i].output) == cast(int) (i * i));
        }
    }
}

unittest
{
    shared ScalarTaskRecord!long record;
    auto pool = new SubmissionWorkerPool(2, 2);
    TaskRef task = prepareScalar(&record, &twice, 21L);
    assert(pool.trySubmit(task) == SubmissionResult.accepted);

    pool.closeAndJoin();
    assert(atomicLoad!(MemoryOrder.acq)(record.done) == 1u);
    assert(atomicLoad!(MemoryOrder.raw)(record.output) == 42L);
}
