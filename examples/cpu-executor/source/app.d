module app;

import concurrency : Executor, TaskHandle;
import core.thread : Thread;
import core.time : MonoTime, dur;
import core.memory : GC;
import std.exception : enforce;
import std.stdio : writeln;

private struct Result { ulong sum; Thread worker; }
private struct Chunk
{
    uint first, length;
    Result opCall()
    {
        ulong sum;
        foreach (ulong i; first .. cast(ulong)first + length) sum += i * i;
        return Result(sum, Thread.getThis());
    }
}
private ulong reference(uint first, uint length)
{
    ulong sum;
    foreach (ulong i; first .. cast(ulong)first + length) sum += i * i;
    return sum;
}

void main()
{
    enum count = 48;
    auto controller = Thread.getThis();
    auto executor = new Executor(4, 8, 64);
    scope(exit) executor.closeAndJoin();
    TaskHandle!Result[count] handles;
    bool[count] applied;
    foreach (i; 0 .. count)
    {
        Chunk chunk;
        chunk.first = cast(uint)i * 2048;
        chunk.length = 2048;
        handles[i] = executor.submit(chunk);
    }
    // Event-loop-style completion: no worker receives the aggregate's address.
    ulong aggregate;
    size_t completed;
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (completed != count)
    {
        enforce(MonoTime.currTime < deadline, "completion deadline exceeded");
        foreach (i; 0 .. count)
        {
            if (applied[i] || !handles[i].isComplete()) continue;
            auto result = handles[i].get();
            enforce(Thread.getThis() is controller && result.worker !is controller,
                "completion applied on the wrong thread");
            enforce(result.sum == reference(cast(uint)i * 2048, 2048), "chunk mismatch");
            aggregate += result.sum;
            applied[i] = true;
            ++completed;
        }
        Thread.yield();
    }
    executor.closeAndJoin();
    GC.collect();
    enforce(aggregate == reference(0, count * 2048), "aggregate mismatch");
    foreach (i; 0 .. count)
        enforce(handles[i].get().sum == reference(cast(uint)i * 2048, 2048),
            "result did not survive shutdown");
    writeln("PUBLIC_CPU_PASS chunks=48 controller_affinity=true repeated_get=true");
}
