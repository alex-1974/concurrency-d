/** R0.5 research-only worker fairness and bounded-blocking probe. */
module concurrency.benchmarks.fairness_blocking;

import concurrency.internal.owned_task : OwnedTaskExecutor, OwnedRecordPolicy;
import concurrency.internal.submission_pool : NotificationPolicy;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, ticksToNSecs;
import std.conv : to;
import std.stdio : writefln;

private struct Work {
    shared(uint)* count;
    uint id;
    int opCall() {
        atomicFetchAdd!(MemoryOrder.rel)(*count, 1u);
        return cast(int) id + 7;
    }
}
private struct BlockWork {
    Semaphore gate;
    shared(uint)* started;
    shared(uint)* ended;
    int opCall() {
        atomicFetchAdd!(MemoryOrder.rel)(*started, 1u);
        gate.wait();
        atomicFetchAdd!(MemoryOrder.rel)(*ended, 1u);
        return 91;
    }
}
private Thread makeProducer(OwnedTaskExecutor pool,
                            shared(uint)[] hits, size_t id, size_t producers) {
    return new Thread({
        for (size_t i = id; i < hits.length; i += producers) {
            Work task;
            task.count = &hits[i];
            task.id = cast(uint) i;
            auto handle = pool.submit(task);
            if (i % 17 == 0 && handle.get() != cast(int) i + 7)
                throw new Exception("typed fairness result mismatch");
        }
    });
}
private ulong nanosSince(MonoTime start) {
    return cast(ulong) ticksToNSecs(MonoTime.currTime.ticks - start.ticks);
}
private bool waitStarted(shared(uint)* value, uint target) {
    const begin = MonoTime.currTime;
    while (atomicLoad!(MemoryOrder.acq)(*value) < target) {
        if (nanosSince(begin) > 10_000_000_000UL) return false;
        Thread.yield();
    }
    return true;
}
private bool awaitSiblings(shared(uint)[] hits, ulong timeoutNs) {
    const begin = MonoTime.currTime;
    do {
        bool all = true;
        foreach (ref count; hits)
            if (atomicLoad!(MemoryOrder.acq)(count) != 1u)
                all = false;
        if (all) return true;
        Thread.yield();
    } while (nanosSince(begin) < timeoutNs);
    return false;
}
private void fair(size_t workers, size_t producers, size_t tasks,
                  OwnedRecordPolicy storage, NotificationPolicy notification) {
    auto hits = new shared uint[tasks];
    auto pool = new OwnedTaskExecutor(workers, 64, tasks + workers + 8,
                                      storage, true, notification);
    auto threads = new Thread[producers];
    const start = MonoTime.currTime;
    foreach (i; 0 .. producers) {
        threads[i] = makeProducer(pool, hits, i, producers);
        threads[i].start();
    }
    foreach (t; threads) t.join();
    pool.closeAndJoin();
    if (pool.completedCount() != tasks || pool.acceptedCount() != tasks)
        throw new Exception("fairness completion mismatch");
    foreach (ref hit; hits)
        if (atomicLoad!(MemoryOrder.acq)(hit) != 1u)
            throw new Exception("task executed other than once");
    auto distribution = pool.workerStatsAfterJoin();
    if (distribution.length != workers)
        throw new Exception("missing worker counters");
    ulong sum, maximum;
    size_t active;
    foreach (i, worker; distribution) {
        sum += worker.executions;
        if (worker.executions > maximum) maximum = worker.executions;
        if (worker.executions != 0) ++active;
        writefln("worker,%s,%s", i, worker.executions);
    }
    if (sum != tasks || active == 0)
        throw new Exception("worker fairness accounting mismatch");
    writefln("fairness,%s,%s,%s,%s,%s,%s",
        workers, producers, tasks, active, maximum, nanosSince(start));
}
private void blocking(size_t workers, size_t blocked, size_t siblings,
                      OwnedRecordPolicy storage, NotificationPolicy notification) {
    if (blocked == 0 || blocked > workers || siblings > 64)
        throw new Exception("invalid blocked-worker configuration");
    auto pool = new OwnedTaskExecutor(workers, 64, 512,
                                      storage, true, notification);
    auto gate = new Semaphore(0);
    shared uint started, ended;
    foreach (_; 0 .. blocked) {
        BlockWork task;
        task.gate = gate;
        task.started = &started;
        task.ended = &ended;
        auto handle = pool.submit(task);
    }
    const didStart = waitStarted(&started, cast(uint) blocked);
    if (!didStart) {
        foreach (_; 0 .. blocked) gate.notify();
        pool.closeAndJoin();
        throw new Exception("blocked task never entered semaphore");
    }
    auto hits = new shared uint[siblings];
    foreach (i; 0 .. siblings) {
        Work work;
        work.count = &hits[i];
        work.id = cast(uint) i;
        auto handle = pool.submit(work);
    }
    const beforeRelease = awaitSiblings(hits,
        blocked == workers ? 100_000_000UL : 5_000_000_000UL);
    foreach (_; 0 .. blocked) gate.notify();
    pool.closeAndJoin();
    const expected = blocked < workers;
    if (beforeRelease != expected ||
        atomicLoad!(MemoryOrder.acq)(ended) != blocked ||
        pool.acceptedCount() != blocked + siblings ||
        pool.completedCount() != blocked + siblings)
        throw new Exception("blocked-worker progress/accounting mismatch");
    foreach (ref hit; hits)
        if (atomicLoad!(MemoryOrder.acq)(hit) != 1u)
            throw new Exception("sibling task not executed exactly once");
    auto distribution = pool.workerStatsAfterJoin();
    ulong sum;
    foreach (worker; distribution) sum += worker.executions;
    if (sum != blocked + siblings)
        throw new Exception("blocked worker dispatch accounting mismatch");
    writefln("blocking,%s,%s,%s,%s,%s",
             workers, blocked, siblings, beforeRelease ? 1 : 0, sum);
}
void main(string[] args) {
    auto mode = args.length > 1 ? args[1] : "fair";
    auto notification = args.length > 2 ? args[2] : "always";
    auto storageName = args.length > 3 ? args[3] : "gc";
    size_t workers = args.length > 4 ? to!size_t(args[4]) : 4;
    size_t count = args.length > 5 ? to!size_t(args[5]) : 4;
    size_t tasks = args.length > 6 ? to!size_t(args[6]) : 256;
    if ((mode != "fair" && mode != "block") ||
        (notification != "always" && notification != "waiter") ||
        (storageName != "gc" && storageName != "recycle") ||
        workers == 0 || workers > 64 || count == 0 || count > 64 ||
        tasks == 0 || tasks > 20000)
        throw new Exception("invalid fairness/blocking arguments");
    const n = notification == "always"
        ? NotificationPolicy.always : NotificationPolicy.waiterAware;
    const s = storageName == "gc"
        ? OwnedRecordPolicy.freshGc : OwnedRecordPolicy.recycleTyped;
    if (mode == "fair") fair(workers, count, tasks, s, n);
    else blocking(workers, count, tasks, s, n);
}
