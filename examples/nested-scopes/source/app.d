module app;

import concurrency : Executor, TaskHandle;
import std.exception : enforce;
import std.stdio : writeln;

private struct SumRange
{
    Executor executor;
    ulong first;
    ulong end;
    ulong cutoff;

    this(Executor executor, ulong first, ulong end, ulong cutoff)
    {
        this.executor = executor;
        this.first = first;
        this.end = end;
        this.cutoff = cutoff;
    }

    ulong opCall()
    {
        if (end - first <= cutoff)
        {
            ulong sum;
            foreach (value; first .. end)
                sum += value;
            return sum;
        }

        const middle = first + (end - first) / 2;
        SumRange leftRange = SumRange(executor, first, middle, cutoff);
        SumRange rightRange = SumRange(executor, middle, end, cutoff);
        auto children = executor.join(leftRange, rightRange);
        return children.left + children.right;
    }
}

private ulong sequentialSum(ulong end)
{
    return end * (end - 1) / 2;
}

private ulong parallelSum(size_t workers, ulong end, ulong cutoff)
{
    auto executor = new Executor(workers, 8, 4096);
    scope(exit) executor.closeAndJoin();

    TaskHandle!ulong root;
    executor.withScope(1, (ref rootScope) {
        SumRange range = SumRange(executor, 0UL, end, cutoff);
        root = rootScope.spawn(range);
    });
    const value = root.get();
    executor.closeAndJoin();
    return value;
}

void main()
{
    enum ulong count = 1_048_576;
    enum ulong cutoff = 4_096;
    const expected = sequentialSum(count);

    foreach (workers; [1, 4])
    {
        const actual = parallelSum(workers, count, cutoff);
        enforce(actual == expected, "recursive scoped sum mismatch");
        writeln("workers=", workers, " items=", count,
            " result=", actual);
    }

    writeln("PUBLIC_SCOPE_PASS recursive_fork_join=true single_worker_help=true");
}
