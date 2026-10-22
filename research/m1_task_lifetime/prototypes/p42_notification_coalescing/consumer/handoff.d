// Independent CPU consumer: workers compute values; only the controller
// applies completion to its event-loop state. Research-only @system API.
module concurrency.research.p42_20_handoff;
import concurrency.research.p42_owned : OwnedTaskExecutor;
import core.thread : Thread;
import core.time : MonoTime, dur;
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
private void require(bool ok) { if (!ok) throw new Exception("P42.20 completion handoff check failed"); }
void main()
{
    enum count = 48;
    auto controller = Thread.getThis();
    auto executor = new OwnedTaskExecutor(4, 8, 64);
    // No worker receives a reference to the event-loop-owned aggregate.
    ulong aggregate;
    alias Handle = typeof(executor.submit(Chunk.init));
    Handle[count] handles;
    bool[count] applied;
    foreach (i; 0 .. count)
    {
        Chunk chunk;
        chunk.first = cast(uint)i * 2048;
        chunk.length = 2048;
        handles[i] = executor.submit(chunk);
    }
    size_t completed;
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (completed != count)
    {
        require(MonoTime.currTime < deadline);
        foreach (i; 0 .. count)
        {
            if (applied[i] || !handles[i].isComplete()) continue;
            auto result = handles[i].get();
            require(Thread.getThis() is controller && result.worker !is controller);
            require(result.sum == reference(cast(uint)i * 2048, 2048));
            // Completion application belongs to the consumer thread.
            aggregate += result.sum;
            applied[i] = true;
            ++completed;
        }
        Thread.yield();
    }
    executor.closeAndJoin();
    require(aggregate == reference(0, count * 2048));
    require(executor.acceptedCount() == count && executor.completedCount() == count);
    require(executor.retainedCount() == 0);
    writeln("P42_20_HANDOFF_PASS chunks=48 controller_affinity=true");
}
