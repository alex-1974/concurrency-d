// Deliberately outside package concurrency: no internal imports or access.
module public_api_consumer;

import concurrency : CancellationToken, Executor, TaskHandle, WorkSize, ExecutorClosedException, WorkerSelfJoinException;
import core.atomic : atomicLoad, atomicStore, atomicFetchAdd, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime, dur;
import core.memory : GC;
import std.algorithm.mutation : move;
import std.exception : enforce;
import std.stdio : writeln;

static assert(!__traits(compiles, (Executor e) { e.retainedCount(); }));
static assert(!__traits(compiles, (Executor e) { e._impl; }));
static assert(!__traits(compiles, (TaskHandle!int h) { h._cell; }));

private final class Gate
{
    shared uint entered, released;
    void wait()
    {
        atomicStore!(MemoryOrder.rel)(entered, 1u);
        while (atomicLoad!(MemoryOrder.acq)(released) == 0) Thread.yield();
    }
    void untilEntered()
    {
        const end = MonoTime.currTime + dur!"seconds"(5);
        while (atomicLoad!(MemoryOrder.acq)(entered) == 0)
        {
            enforce(MonoTime.currTime < end, "public consumer blocker did not start");
            Thread.yield();
        }
    }
    void release() { atomicStore!(MemoryOrder.rel)(released, 1u); }
}
private struct Block { Gate gate; void opCall() { gate.wait(); } }
private struct Value { int value; int opCall() { return value * 3; } }
private struct BatchValue
{
    ulong[] values;
    size_t index;
    this(ulong[] values, size_t index) { this.values = values; this.index = index; }
    void opCall() nothrow { values[index] = index + 1; }
}
private struct Hits
{
    shared uint* hits;
    int opCall() { atomicFetchAdd!(MemoryOrder.rel)(*hits, 1u); return 42; }
}
private int functionResult() { return 42; }
private void noop() {}
private struct Fail { void opCall() { throw new Exception("public task exception"); } }
private struct InlineFail { void opCall() { throw new Exception("inline join failure"); } }
private struct SelfClose { Executor executor; void opCall() { executor.closeAndJoin(); } }
private struct SelfScope
{
    Executor executor;
    shared uint* completed;
    void opCall()
    {
        executor.withScope(3, (ref tasks) {
            foreach (_; 0 .. 3)
            {
                Hits child;
                child.hits = completed;
                tasks.spawn(child);
            }
        });
        recursiveScopeLeaves(executor, 2, completed);
    }
}
private struct BorrowedScopeTask
{
    Gate gate;
    int* target;
    int opCall()
    {
        gate.wait();
        *target = 73;
        return 91;
    }
}

private struct CooperativeStop
{
    CancellationToken token;
    Gate* releaseAfterRequest;
    shared uint* observed;
    int* borrowed;

    void opCall()
    {
        while (!token.isCancellationRequested())
            Thread.yield();
        atomicStore!(MemoryOrder.rel)(*observed, 1u);
        releaseAfterRequest.wait();
        *borrowed = 117;
    }
}

private struct CancellationReceipt
{
    CancellationToken token;
    shared uint* observed;

    int opCall()
    {
        const requested = token.isCancellationRequested();
        atomicStore!(MemoryOrder.rel)(*observed, requested ? 1u : 0u);
        return requested ? 1 : 0;
    }
}

private struct CancellationCompletionRace
{
    CancellationToken token;
    Gate gate;
    shared uint* calls;
    shared uint* observed;

    int opCall()
    {
        gate.wait();
        const cancelled = token.isCancellationRequested();
        atomicStore!(MemoryOrder.rel)(*observed, cancelled ? 1u : 0u);
        atomicFetchAdd!(MemoryOrder.rel)(*calls, 1u);
        return cancelled ? 701 : 703;
    }
}

private struct ShutdownCancellation
{
    CancellationToken token;
    shared uint* entered;
    shared uint* calls;

    int opCall()
    {
        atomicStore!(MemoryOrder.rel)(*entered, 1u);
        const end = MonoTime.currTime + dur!"seconds"(5);
        while (!token.isCancellationRequested())
        {
            enforce(MonoTime.currTime < end,
                "shutdown child did not observe cancellation");
            Thread.yield();
        }
        atomicFetchAdd!(MemoryOrder.rel)(*calls, 1u);
        return 811;
    }
}

private void recursiveScopeLeaves(
    Executor executor,
    size_t depth,
    shared uint* completed)
{
    if (depth == 0)
        return;

    Hits leaf;
    leaf.hits = completed;
    executor.withScope(1, (ref tasks) {
        tasks.spawn(leaf);
        recursiveScopeLeaves(executor, depth - 1, completed);
    });
}

private void resultsAndSelfClose()
{
    auto executor = new Executor(2, 8, 8);
    scope(exit) executor.closeAndJoin();
    Value value;
    value.value = 14;
    TaskHandle!int answer = executor.submit(value);
    auto failure = executor.submit(Fail.init);
    SelfClose misuse;
    misuse.executor = executor;
    auto self = executor.submit(misuse);
    enforce(answer.get() == 42 && answer.isComplete(), "typed result mismatch");
    enforce(executor.submit(&functionResult, WorkSize.large).get() == 42,
        "large-work size changed task result");
    enforce(executor.trySubmit(&functionResult, WorkSize.small).get() == 42,
        "small-work size changed task result");
    executor.withScope(1, (ref tasks) {
        enforce(tasks.spawn(&functionResult, WorkSize.large).get() == 42,
            "scoped large-work size changed task result");
    });
    auto hintedJoin = executor.join(&functionResult, &functionResult,
        WorkSize.large);
    enforce(hintedJoin.left == 42 && hintedJoin.right == 42,
        "join large-work size changed results");
    enforce(executor.submit(&functionResult).get() == 42, "function pointer submission failed");
    auto closure = () { return value.value * 3; };
    // Caller keeps captured value alive through the explicit join below.
    enforce(executor.submit(closure).get() == 42, "delegate submission failed");
    bool caught;
    try { failure.get(); }
    catch (Exception error) { caught = error.msg == "public task exception"; }
    enforce(caught, "task exception lost");
    caught = false;
    try { self.get(); }
    catch (WorkerSelfJoinException) { caught = true; }
    enforce(caught, "public self-close error not typed");
    enforce(executor.submit(value).get() == 42, "self-close changed admission");
    executor.closeAndJoin();
    GC.collect();
    enforce(answer.get() == 42, "result lost after join");
    caught = false;
    try { failure.get(); }
    catch (Exception error) { caught = error.msg == "public task exception"; }
    enforce(caught, "error cell lost after join");
    caught = false;
    try { executor.trySubmit(value); }
    catch (ExecutorClosedException) { caught = true; }
    enforce(caught, "closed trySubmit did not reject");
    caught = false;
    try { executor.submit(value); }
    catch (ExecutorClosedException) { caught = true; }
    enforce(caught, "closed submit did not terminate");
}

private void batchSubmission()
{
    auto executor = new Executor(2, 4, 8);
    scope(exit) executor.closeAndJoin();

    auto values = new ulong[4];
    BatchValue[4] jobs;
    foreach (index; 0 .. jobs.length)
        jobs[index] = BatchValue(values, index);
    auto handles = executor.submitBatch(jobs[]);
    enforce(handles.length == jobs.length,
        "submitBatch must return one handle per callable");
    ulong total;
    foreach (handle; handles)
        handle.get();
    foreach (value; values)
        total += value;
    enforce(total == 10, "submitBatch must execute every callable once");

    BatchValue[] empty;
    enforce(executor.submitBatch(empty[]).length == 0,
        "empty submitBatch must return an empty handle array");

    BatchValue[5] oversized;
    bool rejected;
    try { executor.submitBatch(oversized[]); }
    catch (Exception error)
        rejected = error.msg == "submitBatch exceeds executor capacity";
    enforce(rejected,
        "submitBatch larger than ingress capacity must fail instead of waiting forever");

    auto bounded = new Executor(1, 2, 4);
    auto gate = new Gate;
    scope(exit) { gate.release(); bounded.closeAndJoin(); }
    Block blockerJob;
    blockerJob.gate = gate;
    auto blocker = bounded.submit(blockerJob);
    gate.untilEntered();
    auto queued = bounded.submit(&functionResult);
    auto delayedRelease = new Thread({
        Thread.sleep(dur!"msecs"(10));
        gate.release();
    });
    delayedRelease.start();
    auto admitted = bounded.submitBatch(jobs[0 .. 2]);
    delayedRelease.join();
    blocker.get();
    enforce(queued.get() == 42,
        "queued task must complete before waiting batch admission");
    foreach (handle; admitted)
        handle.get();
    enforce(values[0] == 1 && values[1] == 2,
        "waiting batch admission must publish all tasks");
}

private void parallelForRanges()
{
    auto executor = new Executor(2, 4, 16);
    scope(exit) executor.closeAndJoin();
    auto values = new size_t[10];
    shared uint[10] visits;
    executor.parallelFor(values.length, 3, (size_t index) {
        values[index] = index + 1;
        atomicFetchAdd!(MemoryOrder.rel)(visits[index], 1u);
    });
    size_t total;
    foreach (value; values) total += value;
    enforce(total == 55, "parallelFor must visit each index exactly once");
    foreach (count; visits)
        enforce(atomicLoad!(MemoryOrder.acq)(count) == 1,
            "parallelFor must not duplicate index visits");
    executor.parallelFor(0, 3, (size_t index) {});

    shared uint[37] smallWorkVisits;
    executor.parallelFor(37, (size_t index) {
        atomicFetchAdd!(MemoryOrder.rel)(smallWorkVisits[index], 1u);
    }, WorkSize.small);
    foreach (count; smallWorkVisits)
        enforce(atomicLoad!(MemoryOrder.acq)(count) == 1,
            "small-work hint must visit each index exactly once");

    shared uint[37] largeWorkVisits;
    executor.parallelFor(37, (size_t index) {
        atomicFetchAdd!(MemoryOrder.rel)(largeWorkVisits[index], 1u);
    }, WorkSize.large);
    foreach (count; largeWorkVisits)
        enforce(atomicLoad!(MemoryOrder.acq)(count) == 1,
            "large-work hint must visit each index exactly once");
    executor.parallelFor(0, (size_t index) {}, WorkSize.small);

    auto adaptiveValues = new size_t[37];
    shared uint[37] adaptiveVisits;
    executor.parallelForAdaptive(adaptiveValues.length, 1, (size_t index) {
        adaptiveValues[index] = index + 1;
        atomicFetchAdd!(MemoryOrder.rel)(adaptiveVisits[index], 1u);
    });
    size_t adaptiveTotal;
    foreach (value; adaptiveValues) adaptiveTotal += value;
    enforce(adaptiveTotal == 703,
        "adaptive parallelFor must visit every index exactly once");
    foreach (count; adaptiveVisits)
        enforce(atomicLoad!(MemoryOrder.acq)(count) == 1,
            "adaptive parallelFor must not duplicate index visits");

    shared uint[2] tinyAdaptiveVisits;
    executor.parallelForAdaptive(2, 1, (size_t index) {
        atomicFetchAdd!(MemoryOrder.rel)(tinyAdaptiveVisits[index], 1u);
    });
    foreach (count; tinyAdaptiveVisits)
        enforce(atomicLoad!(MemoryOrder.acq)(count) == 1,
            "adaptive parallelFor must handle fewer blocks than workers");

    shared uint oneItemVisits;
    executor.parallelForAdaptive(1, 64, (size_t index) {
        enforce(index == 0, "adaptive parallelFor one-item index must be zero");
        atomicFetchAdd!(MemoryOrder.rel)(oneItemVisits, 1u);
    });
    enforce(atomicLoad!(MemoryOrder.acq)(oneItemVisits) == 1,
        "adaptive parallelFor must handle minGrainSize larger than itemCount");

    bool rejected;
    try { executor.parallelFor(1, 0, (size_t index) {}); }
    catch (Exception error)
        rejected = error.msg == "parallelFor grainSize must be positive";
    enforce(rejected, "parallelFor must reject zero grainSize");
    rejected = false;
    try { executor.parallelForAdaptive(1, 0, (size_t index) {}); }
    catch (Exception error)
        rejected = error.msg == "parallelForAdaptive minGrainSize must be positive";
    enforce(rejected, "adaptive parallelFor must reject zero minGrainSize");

    bool failed;
    try
        executor.parallelFor(8, 1, (size_t index) {
            if (index == 2) throw new Exception("parallelFor callback failure");
        });
    catch (Exception error)
        failed = error.msg == "parallelFor callback failure";
    enforce(failed, "parallelFor must propagate callback failures after draining");
    enforce(executor.submit(&functionResult).get() == 42,
        "executor must remain usable after a parallelFor callback failure");

    bool adaptiveFailed;
    try
        executor.parallelForAdaptive(64, 1, (size_t index) {
            if (index == 2) throw new Exception("adaptive callback failure");
        });
    catch (Exception error)
        adaptiveFailed = error.msg == "adaptive callback failure";
    enforce(adaptiveFailed,
        "adaptive parallelFor must drain workers and propagate callback failures");
    enforce(executor.submit(&functionResult).get() == 42,
        "executor must remain usable after an adaptive callback failure");

    auto singleWorker = new Executor(1, 1, 8);
    scope(exit) singleWorker.closeAndJoin();
    size_t singleTotal;
    singleWorker.parallelFor(7, 2, (size_t index) { singleTotal += index; });
    enforce(singleTotal == 21, "single-worker parallelFor must visit every index");
    singleWorker.parallelForAdaptive(7, 2,
        (size_t index) { singleTotal += index; });
    enforce(singleTotal == 42,
        "single-worker adaptive parallelFor must visit every index");
    bool singleFailed;
    try
        singleWorker.parallelFor(4, 1, (size_t index) {
            if (index == 1) throw new Exception("single-worker callback failure");
        });
    catch (Exception error)
        singleFailed = error.msg == "single-worker callback failure";
    enforce(singleFailed, "single-worker parallelFor must propagate callback failures");
    singleTotal = 0;
    singleWorker.parallelFor(2, 1, (size_t index) { singleTotal += index; });
    enforce(singleTotal == 1, "single-worker executor must remain usable after failure");
}

private void backpressure()
{
    // Single worker executing a void blocker; then one queued task fills ingress.
    auto executor = new Executor(1, 1, 4);
    auto gate = new Gate;
    scope(exit) { gate.release(); executor.closeAndJoin(); }
    Block block;
    block.gate = gate;
    TaskHandle!void blocker = executor.submit(block);
    gate.untilEntered();
    auto hits = new shared uint[2];
    Hits queued;
    queued.hits = &hits[0];
    auto accepted = executor.trySubmit(queued);
    enforce(accepted !is null, "queue not admitted");
    Hits rejected;
    rejected.hits = &hits[1];
    enforce(executor.trySubmit(rejected) is null, "full inbox did not reject");
    gate.release();
    executor.closeAndJoin();
    blocker.get();
    enforce(accepted.get() == 42 && atomicLoad!(MemoryOrder.acq)(hits[0]) == 1 &&
        atomicLoad!(MemoryOrder.acq)(hits[1]) == 0, "rejection created an obligation");

    // Independent retained-budget exhaustion with an otherwise empty inbox.
    auto limited = new Executor(1, 8, 1);
    auto held = new Gate;
    scope(exit) { held.release(); limited.closeAndJoin(); }
    block.gate = held;
    auto only = limited.submit(block);
    held.untilEntered();
    enforce(limited.trySubmit(queued) is null, "record budget did not reject");
    held.release();
    only.get();
    // get may precede returned-marker reclamation; submit retries that boundary.
    enforce(limited.submit(queued).get() == 42, "record budget was not reclaimed");
    limited.closeAndJoin();
}

private void multipleResultWaiters()
{
    auto executor = new Executor(1, 2, 4);
    auto gate = new Gate;
    scope(exit) { gate.release(); executor.closeAndJoin(); }

    Block block;
    block.gate = gate;
    auto blocker = executor.submit(block);
    gate.untilEntered();

    Value value;
    value.value = 14;
    auto result = executor.submit(value);
    shared uint ready;
    int[2] observed;
    auto first = new Thread({
        atomicFetchAdd!(MemoryOrder.rel)(ready, 1u);
        observed[0] = result.get();
    });
    auto second = new Thread({
        atomicFetchAdd!(MemoryOrder.rel)(ready, 1u);
        observed[1] = result.get();
    });
    first.start();
    second.start();

    const end = MonoTime.currTime + dur!"seconds"(5);
    while (atomicLoad!(MemoryOrder.acq)(ready) != 2u)
    {
        enforce(MonoTime.currTime < end,
            "multiple TaskHandle.get waiters did not start");
        Thread.yield();
    }
    // Both waiters announce immediately before entering get(). Keep the task
    // blocked briefly so they can reach its condition wait before completion.
    Thread.sleep(dur!"msecs"(25));
    gate.release();
    first.join();
    second.join();
    blocker.get();
    enforce(observed[0] == 42 && observed[1] == 42,
        "result completion did not release every handle waiter");
    executor.closeAndJoin();
}

private void scopedTasksAndUnwind()
{
    auto executor = new Executor(2, 4, 16);
    scope(exit) executor.closeAndJoin();

    // A body exception must not let borrowed caller storage expire while an
    // accepted child can still write through its captured pointer.
    int borrowed;
    auto gate = new Gate;
    TaskHandle!int completed;
    bool bodyFailureObserved;
    try
    {
        executor.withScope(4, (ref tasks) {
            BorrowedScopeTask job;
            job.gate = gate;
            job.target = &borrowed;
            completed = tasks.spawn(job);
            gate.untilEntered();
            gate.release();
            throw new Exception("scope body failure");
        });
    }
    catch (Exception error)
    {
        bodyFailureObserved = error.msg == "scope body failure";
    }
    enforce(bodyFailureObserved && borrowed == 73,
        "scope returned before borrowed child or lost the body exception");
    enforce(completed.get() == 91, "scope child result was lost");

    TaskHandle!void voidResult;
    executor.withScope(1, (ref tasks) {
        voidResult = tasks.spawn(&noop);
    });
    voidResult.get();

    // Join drains every child before propagating a task error.
    shared uint ran;
    Hits increment;
    increment.hits = &ran;
    bool childFailureObserved;
    try
    {
        executor.withScope(4, (ref tasks) {
            tasks.spawn(increment);
            tasks.spawn(Fail.init);
            tasks.spawn(increment);
        });
    }
    catch (Exception error)
    {
        childFailureObserved = error.msg == "public task exception";
    }
    enforce(childFailureObserved && atomicLoad!(MemoryOrder.acq)(ran) == 2,
        "scope did not drain siblings before propagating child failure");

    bool capacityObserved;
    try
    {
        executor.withScope(1, (ref tasks) {
            tasks.spawn(&functionResult);
            tasks.spawn(&functionResult);
        });
    }
    catch (Exception error)
    {
        capacityObserved = error.msg == "scope maxTasks exceeded";
    }
    enforce(capacityObserved, "scope maxTasks was not enforced");

    // Nested lexical groups may be opened by the external controller; each
    // group still drains its own children before returning to its parent.
    shared uint nestedCompleted;
    Hits outerChild;
    outerChild.hits = &nestedCompleted;
    Hits innerChild;
    innerChild.hits = &nestedCompleted;
    executor.withScope(2, (ref outer) {
        outer.spawn(outerChild);
        executor.withScope(1, (ref inner) {
            inner.spawn(innerChild);
        });
    });
    enforce(atomicLoad!(MemoryOrder.acq)(nestedCompleted) == 2,
        "nested lexical scopes did not drain both child groups");

    // Moving the public view must not move the join obligation out of the
    // withScope frame. The frame retains its own reference to the state.
    int movedBorrowed;
    auto movedGate = new Gate;
    BorrowedScopeTask movedChild;
    movedChild.gate = movedGate;
    movedChild.target = &movedBorrowed;
    auto movedReleaser = new Thread({
        movedGate.untilEntered();
        movedGate.release();
    });
    movedReleaser.start();
    executor.withScope(1, (ref tasks) {
        auto moved = move(tasks);
        moved.spawn(movedChild);
    });
    movedReleaser.join();
    enforce(movedBorrowed == 73,
        "moving the TaskScope view bypassed the borrowed lifetime join");

    recursiveScopeLeaves(executor, 3, &nestedCompleted);
    enforce(atomicLoad!(MemoryOrder.acq)(nestedCompleted) == 5,
        "recursive lexical scopes lost a child");

    // Two-way join returns typed values, handles void on either side, and
    // drains the forked child if the inline branch throws.
    Value leftValue;
    leftValue.value = 13;
    auto pair = executor.join(leftValue, &functionResult);
    enforce(pair.left == 39 && pair.right == 42,
        "fork-join lost or mis-typed a value result");
    auto rightOnly = executor.join(&noop, &functionResult);
    enforce(rightOnly.right == 42, "fork-join mishandled a void left result");
    auto leftOnly = executor.join(&functionResult, &noop);
    enforce(leftOnly.left == 42, "fork-join mishandled a void right result");
    executor.join(&noop, &noop);

    shared uint inlineFailureDrain;
    Hits joinChild;
    joinChild.hits = &inlineFailureDrain;
    bool inlineFailureObserved;
    try
        executor.join(joinChild, InlineFail.init);
    catch (Exception error)
        inlineFailureObserved = error.msg == "inline join failure";
    enforce(inlineFailureObserved &&
            atomicLoad!(MemoryOrder.acq)(inlineFailureDrain) == 1,
        "fork-join returned before draining its child after inline failure");

    bool forkedFailureObserved;
    try
        executor.join(Fail.init, &noop);
    catch (Exception error)
        forkedFailureObserved = error.msg == "public task exception";
    enforce(forkedFailureObserved,
        "fork-join lost the forked child's failure");

    // A worker recursively opens scopes. With one worker, only cooperative
    // helping can run each nested child and complete the outer task.
    auto singleWorker = new Executor(1, 1, 8);
    scope(exit) singleWorker.closeAndJoin();
    shared uint workerRecursiveCompleted;
    SelfScope nested;
    nested.executor = singleWorker;
    nested.completed = &workerRecursiveCompleted;
    auto workerScope = singleWorker.submit(nested);
    workerScope.get();
    enforce(atomicLoad!(MemoryOrder.acq)(workerRecursiveCompleted) == 5,
        "single worker did not help admitted or recursive scoped children");
    singleWorker.closeAndJoin();
}

private void cooperativeCancellation()
{
    CancellationToken inert;
    enforce(!inert.isCancellationRequested(), "default token was not inert");
    inert.requestCancellation();

    auto executor = new Executor(1, 4, 4);
    scope(exit) executor.closeAndJoin();

    auto requestObserved = new Gate;
    shared uint observed;
    int borrowed;
    executor.withScope(1, (ref tasks) {
        scope(exit) requestObserved.release();
        auto token = tasks.cancellationToken();
        CooperativeStop child;
        child.token = token;
        child.releaseAfterRequest = &requestObserved;
        child.observed = &observed;
        child.borrowed = &borrowed;
        tasks.spawn(child);

        tasks.requestCancellation();
        token.requestCancellation(); // repeated requests are harmless
        const end = MonoTime.currTime + dur!"seconds"(5);
        while (atomicLoad!(MemoryOrder.acq)(observed) == 0)
        {
            enforce(MonoTime.currTime < end,
                "child did not observe cooperative cancellation");
            Thread.yield();
        }
        requestObserved.untilEntered();
        requestObserved.release();
    });

    enforce(borrowed == 117,
        "scope returned before cooperatively cancelled child quiesced");

    // A request made before publication remains observable by a later child.
    shared uint alreadyRequested;
    TaskHandle!int preRequested;
    executor.withScope(1, (ref tasks) {
        auto token = tasks.cancellationToken();
        tasks.requestCancellation();
        CancellationReceipt child;
        child.token = token;
        child.observed = &alreadyRequested;
        preRequested = tasks.spawn(child);
    });
    enforce(preRequested.get() == 1 &&
        atomicLoad!(MemoryOrder.acq)(alreadyRequested) == 1,
        "child published after cancellation missed the request");

    // Hold the sole worker so cancellation is requested while the child is
    // accepted but queued; it must still run and observe the signal.
    auto queuedGate = new Gate;
    scope(exit) queuedGate.release();
    Block blocker;
    blocker.gate = queuedGate;
    auto blockedWorker = executor.submit(blocker);
    queuedGate.untilEntered();
    shared uint queuedObserved;
    TaskHandle!int queuedChild;
    executor.withScope(1, (ref tasks) {
        CancellationReceipt child;
        child.token = tasks.cancellationToken();
        child.observed = &queuedObserved;
        queuedChild = tasks.spawn(child);
        tasks.requestCancellation();
        queuedGate.release();
    });
    blockedWorker.get();
    enforce(queuedChild.get() == 1 &&
        atomicLoad!(MemoryOrder.acq)(queuedObserved) == 1,
        "queued child did not observe cancellation or was not joined");

    // Release and cancellation become visible concurrently. Cancellation is
    // a signal, not a competing result publisher: the callable runs once and
    // its one selected value remains stable across repeated get calls.
    foreach (_; 0 .. 64)
    {
        auto finish = new Gate;
        shared uint calls;
        shared uint raceObserved;
        TaskHandle!int raced;
        CancellationToken escaped;
        executor.withScope(1, (ref tasks) {
            escaped = tasks.cancellationToken();
            CancellationCompletionRace child;
            child.token = escaped;
            child.gate = finish;
            child.calls = &calls;
            child.observed = &raceObserved;
            raced = tasks.spawn(child);
            finish.untilEntered();

            auto requester = new Thread({
                while (atomicLoad!(MemoryOrder.acq)(finish.released) == 0)
                    Thread.yield();
                escaped.requestCancellation();
            });
            requester.start();
            finish.release();
            requester.join();
        });

        const value = raced.get();
        enforce((value == 701 || value == 703) && raced.get() == value,
            "cancel/complete race did not preserve one stable result");
        enforce(atomicLoad!(MemoryOrder.acq)(calls) == 1u,
            "cancel/complete race executed the callback more than once");
        enforce((value == 701) ==
                (atomicLoad!(MemoryOrder.acq)(raceObserved) == 1u),
            "cancel/complete result disagreed with the callback observation");
        enforce(escaped.isCancellationRequested(),
            "escaped token lost its published request after scope exit");
    }
}

private void cancellationDuringShutdown()
{
    foreach (_; 0 .. 16)
    {
        auto executor = new Executor(1, 2, 4);
        TaskHandle!int completed;
        Thread closer;
        shared uint childEntered;
        shared uint calls;
        shared uint closerStarted;
        shared uint closerFinished;

        executor.withScope(1, (ref tasks) {
            ShutdownCancellation child;
            child.token = tasks.cancellationToken();
            child.entered = &childEntered;
            child.calls = &calls;
            completed = tasks.spawn(child);

            const end = MonoTime.currTime + dur!"seconds"(5);
            while (atomicLoad!(MemoryOrder.acq)(childEntered) == 0u)
            {
                enforce(MonoTime.currTime < end,
                    "shutdown cancellation child did not start");
                Thread.yield();
            }

            closer = new Thread({
                atomicStore!(MemoryOrder.rel)(closerStarted, 1u);
                executor.closeAndJoin();
                atomicStore!(MemoryOrder.rel)(closerFinished, 1u);
            });
            closer.start();
            while (atomicLoad!(MemoryOrder.acq)(closerStarted) == 0u)
                Thread.yield();
            tasks.requestCancellation();
        });

        closer.join();
        enforce(completed.get() == 811 && completed.get() == 811,
            "shutdown cancellation lost the task's stable result");
        enforce(atomicLoad!(MemoryOrder.acq)(calls) == 1u &&
                atomicLoad!(MemoryOrder.acq)(closerFinished) == 1u,
            "shutdown cancellation duplicated work or failed to join");
    }
}

private final class Graph
{
    int number;
    Graph tail;
    this(int n, Graph t = null) { number = n; tail = t; }
}
private struct GraphJob
{
    Graph payload;
    shared uint* receipt;
    int opCall()
    {
        const value = payload.number + payload.tail.number + payload.tail.tail.number;
        atomicFetchAdd!(MemoryOrder.rel)(*receipt, cast(uint)value);
        return value;
    }
}
private void queueGraphsAndDrop(Executor executor, shared uint[] receipts)
{
    foreach (i; 0 .. receipts.length)
    {
        GraphJob job;
        job.payload = new Graph(1, new Graph(2, new Graph(3)));
        job.receipt = &receipts[i];
        auto handle = executor.submit(job);
        handle = null;
    }
}
private void gcAndDroppedHandles()
{
    auto executor = new Executor(1, 8, 16);
    auto gate = new Gate;
    scope(exit) { gate.release(); executor.closeAndJoin(); }
    Block block;
    block.gate = gate;
    auto blocker = executor.submit(block);
    gate.untilEntered();
    auto receipts = new shared uint[8];
    queueGraphsAndDrop(executor, receipts);
    foreach (_; 0 .. 4) GC.collect();
    foreach (ref receipt; receipts)
        enforce(atomicLoad!(MemoryOrder.acq)(receipt) == 0, "queued graph ran before release");
    gate.release();
    executor.closeAndJoin();
    foreach (ref receipt; receipts)
        enforce(atomicLoad!(MemoryOrder.acq)(receipt) == 6, "dropped-handle graph lost or duplicated");
    blocker.get();

    // A scoped task keeps the same transitive GC graph reachable even when
    // its individual handle is dropped and collection runs before dispatch.
    auto scopedExecutor = new Executor(1, 4, 8);
    scope(exit) scopedExecutor.closeAndJoin();
    auto scopedGate = new Gate;
    Block scopedBlocker;
    scopedBlocker.gate = scopedGate;
    auto scopedBlocked = scopedExecutor.submit(scopedBlocker);
    scopedGate.untilEntered();
    shared uint scopedReceipt;
    scopedExecutor.withScope(1, (ref tasks) {
        GraphJob job;
        job.payload = new Graph(4, new Graph(5, new Graph(6)));
        job.receipt = &scopedReceipt;
        auto dropped = tasks.spawn(job);
        dropped = null;
        foreach (_; 0 .. 4)
            GC.collect();
        enforce(atomicLoad!(MemoryOrder.acq)(scopedReceipt) == 0u,
            "scoped graph ran before blocker release");
        scopedGate.release();
    });
    scopedBlocked.get();
    enforce(atomicLoad!(MemoryOrder.acq)(scopedReceipt) == 15u,
        "scoped dropped-handle GC graph was not retained through join");
    scopedExecutor.closeAndJoin();
}
private Thread producer(Executor executor, shared uint[] hits, shared uint[] accepted,
    size_t first, size_t last)
{
    return new Thread({
        foreach (i; first .. last)
        {
            Hits job;
            job.hits = &hits[i];
            for (;;)
            {
                try
                {
                    if (executor.trySubmit(job) is null) { Thread.yield(); continue; }
                    atomicStore!(MemoryOrder.rel)(accepted[i], 1u);
                    break;
                }
                catch (ExecutorClosedException) { return; }
            }
        }
    });
}
private void concurrentClose()
{
    foreach (_; 0 .. 8)
    {
        auto executor = new Executor(4, 8, 32);
        auto hits = new shared uint[128];
        auto accepted = new shared uint[128];
        Hits seedJob;
        seedJob.hits = &hits[0];
        auto seed = executor.submit(seedJob);
        atomicStore!(MemoryOrder.rel)(accepted[0], 1u);
        Thread[] producers;
        foreach (i; 0 .. 4)
            producers ~= producer(executor, hits, accepted,
                1 + i * 127 / 4, 1 + (i + 1) * 127 / 4);
        foreach (p; producers) p.start();
        auto otherCloser = new Thread({ executor.closeAndJoin(); });
        otherCloser.start();
        executor.closeAndJoin();
        otherCloser.join();
        foreach (p; producers) p.join();
        foreach (i; 0 .. hits.length)
            enforce(atomicLoad!(MemoryOrder.acq)(hits[i]) == atomicLoad!(MemoryOrder.acq)(accepted[i]),
                "public close/admission race lost or duplicated a task");
        enforce(seed.get() == 42, "seed result lost");
    }
}

void main()
{
    resultsAndSelfClose();
    batchSubmission();
    parallelForRanges();
    backpressure();
    multipleResultWaiters();
    scopedTasksAndUnwind();
    cooperativeCancellation();
    cancellationDuringShutdown();
    gcAndDroppedHandles();
    concurrentClose();
    // Long-lived executor must re-use its retained budget without public sweep.
    auto bounded = new Executor(2, 2, 2);
    scope(exit) bounded.closeAndJoin();
    Value value;
    value.value = 14;
    foreach (_; 0 .. 256) enforce(bounded.submit(value).get() == 42, "budget stalled");
    bounded.closeAndJoin();
    foreach (limits; [[0, 1, 1], [1, 0, 1], [1, 1, 0]])
    {
        bool rejected;
        try { auto invalid = new Executor(limits[0], limits[1], limits[2]); }
        catch (Exception) { rejected = true; }
        enforce(rejected, "invalid limits accepted");
    }
    writeln("PUBLIC_API_PASS typed_void_error=true batch_submission=atomic,typed_handles,empty,capacity result_waiters=2 backpressure=ingress,records scopes=borrow,unwind,errors,capacity,nested,recursion,moved_view,gc_graph fork_join=typed,void,inline_failure_drain parallel_for=dynamic_ranges,empty,zero_grain,callback_failure,reuse worker_help=admission,join cancellation=running,prepublish,queued,complete_race64,shutdown16 gc_graphs=owned8,scoped1 close_races=8 budget_reuse=256");
}
