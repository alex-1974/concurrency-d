module app;

import concurrency : CancellationToken, Executor, TaskHandle;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.exception : enforce;
import std.stdio : writeln;

private enum taskCount = 24;

private struct Completion
{
    size_t id;
    ulong value;
    bool cancelled;
    Thread worker;
}

/** A consumer-owned, synchronized handoff queue. Workers only post values. */
private final class MainQueue
{
    private Mutex _mutex;
    private Completion[taskCount] _items;
    private size_t _head;
    private size_t _tail;

    this() { _mutex = new Mutex(); }

    void post(Completion item)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        enforce(_tail < _items.length, "completion queue capacity exceeded");
        _items[_tail++] = item;
    }

    bool tryPop(out Completion item)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (_head == _tail)
            return false;
        item = _items[_head++];
        return true;
    }
}

private struct Work
{
    MainQueue queue;
    CancellationToken cancellation;
    size_t id;

    this(MainQueue queue, CancellationToken cancellation, size_t id)
    {
        this.queue = queue;
        this.cancellation = cancellation;
        this.id = id;
    }

    Completion opCall()
    {
        ulong value;
        bool wasCancelled;
        // Poll cooperatively so the controller can cancel queued or long work.
        foreach (ulong i; 0 .. 300_000)
        {
            if ((i & 1023) == 0 && cancellation.isCancellationRequested)
            {
                wasCancelled = true;
                break;
            }
            value += (i + id) * (i + 1);
        }

        Completion result = Completion(id, value, wasCancelled, Thread.getThis());
        queue.post(result);
        return result;
    }
}

void main()
{
    auto controller = Thread.getThis();
    auto queue = new MainQueue();
    auto executor = new Executor(4, 8, taskCount);
    scope (exit) executor.closeAndJoin();

    TaskHandle!Completion[taskCount] handles;
    size_t applied;
    size_t cancelled;
    bool[taskCount] seen;
    ulong controllerState;

    // The scope owns every accepted task through post-dispatch return. The
    // event loop pumps only the consumer-owned queue on the controller thread.
    executor.withScope(cast(size_t) taskCount, (ref tasks) {
        auto token = tasks.cancellationToken();
        foreach (i; 0 .. taskCount)
        {
            Work work = Work(queue, token, cast(size_t) i);
            handles[i] = tasks.spawn(work);
        }

        const deadline = MonoTime.currTime + dur!"seconds"(10);
        while (applied != taskCount)
        {
            enforce(MonoTime.currTime < deadline, "event-loop deadline exceeded");
            Completion completion;
            if (!queue.tryPop(completion))
            {
                Thread.yield();
                continue;
            }

            enforce(Thread.getThis() is controller,
                "consumer state updated outside controller thread");
            enforce(completion.worker !is controller,
                "worker unexpectedly ran on controller thread");
            enforce(completion.id < taskCount && !seen[completion.id],
                "duplicate or invalid completion");

            // Deterministically exercise cancellation and still drain every
            // accepted task through the same queue and lexical join boundary.
            if (applied == 3)
                tasks.requestCancellation();

            seen[completion.id] = true;
            controllerState += completion.value;
            cancelled += completion.cancelled;
            ++applied;
        }
    });

    executor.closeAndJoin();
    foreach (i; 0 .. taskCount)
        enforce(handles[i].get().id == i, "task result mismatch after shutdown");
    enforce(cancelled != 0, "cooperative cancellation was not observed");
    enforce(controllerState != 0, "controller state was not updated");
    writeln("EVENT_LOOP_PASS completions=", applied,
        " cancelled=", cancelled, " controller_affinity=true shutdown=true");
}
