/++
 P04 RESEARCH ONLY — a constrained @safe lexical task execution envelope.
 Scalar inputs are copied before publication, user work is a pure @safe
 nothrow @nogc FUNCTION pointer (not a captured delegate), records never
 escape, all workers are joined before returning by-value result storage.

 The single narrowly scoped @trusted launch function below carries the
 manual invariant proof for internal Thread/Condition/@system operations;
 this is NOT approval for arbitrary borrowed @safe dynamic TaskScope.
+/
module concurrency.research.m1_value_scope;

import concurrency.internal.task_record : TaskHeader, TaskRef, dispatchTask;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
version (M1P07FailStop)
{
    import core.stdc.stdlib : abort;
    import core.stdc.stdio : fputs, fflush, stderr;
}
version (M1P07JoinFault)
    import core.thread.threadbase : ThreadException;
version (M1P07StartFault)
    import core.thread.threadbase : ThreadError;

enum size_t ValueCapacity = 8;
private enum size_t WorkerCount = 2;

alias ScalarOperation = int function(int) @safe pure nothrow @nogc;

struct ScalarBatchResult
{
    size_t count;
    int[ValueCapacity] values;
}

private struct Record
{
    @disable this(this);
    TaskHeader header;
    ScalarOperation operation;
    int argument;
    int result;

    static assert(header.offsetof == 0);

    void prepare(ScalarOperation action, int value) @safe
    {
        operation = action;
        argument = value;
        header.execute = &execute;
    }

    TaskRef reference() @system
    {
        return TaskRef(cast(shared(TaskHeader)*) &header);
    }
}

static assert(!__traits(compiles, {
    Record a;
    Record b = a;
}), "A published record must not be copied");

private Record* fromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    // Private stack-pinned Record[ValueCapacity], header at offset zero,
    // no access after join, no user-provided pointer can enter this path.
    return cast(Record*) raw;
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = fromHeader(raw);
    // P06 fatal-Error probe is deliberately NOT part of the normal binary.
    // The exception is an Error (permitted by nothrow), not an Exception.
    version (M1P06Fatal)
    {
        if (record.argument == int.min)
            assert(0, "P06 injected worker Error");
    }
    record.result = record.operation(record.argument);
}

// Only modified/read by the controller in the P06 fatal-worker probe.
version (M1P06Fatal)
{
    private size_t p06LastJoined;
    private size_t p06LastAccepted;
    private size_t p06LastCompleted;
    private size_t p06LastPending;
}

// P07 deliberately destructive research-only policy: if the native worker
// lifecycle cannot establish quiescence, no caller is allowed to unwind
// stack-resident TaskRef storage.  A process abort is an availability loss,
// not a recoverable exception or an accepted production policy.
version (M1P07FailStop)
private void p07FailStop(const(char)* marker) @system
{
    fputs(marker, stderr);
    fflush(stderr);
    abort();
}

private final class WorkerBatch
{
    private Mutex mutex;
    private Condition workReady;
    private TaskRef[ValueCapacity] inbox;
    private Thread[WorkerCount] workers;
    private size_t head;
    private size_t pending;
    private size_t accepted;
    private size_t completed;
    private size_t started;
    private bool closing;
    private bool joined;

    // Test-only, controller-thread flags: these do not enter any worker.
    version (M1P06Start)
        private size_t failBeforeStart = size_t.max;
    version (M1P06Start)
        private size_t confirmedJoins;

    this()
    {
        mutex = new Mutex();
        workReady = new Condition(mutex);
    }

    void start() @system
    {
        try
        {
            foreach (ref worker; workers)
            {
                version (M1P06Start)
                {
                    if (started == failBeforeStart)
                        throw new Exception("P06 injected pre-start failure");
                }
                worker = new Thread({ workerLoop(); });
                worker.start();
                version (M1P07StartFault)
                {
                    // Simulates a start() reporting failure *after* native
                    // launch, before the caller records a started worker.
                    // It is not a real pthread_attr_destroy failure.
                    if (started == 0)
                        throw new ThreadError(
                            "P07 synthetic post-launch start failure");
                }
                ++started;
            }
            version (M1P06Start)
            {
                if (started == failBeforeStart)
                    throw new Exception("P06 injected pre-start failure");
            }
        }
        catch (Throwable problem)
        {
            version (M1P07FailStop)
            {
                // Any start() failure is conservative fail-stop, because
                // the exact post-native-launch state is not established.
                p07FailStop("P07_FAILSTOP_START\n".ptr);
            }
            else
            {
                closeAndJoin();
                throw problem;
            }
        }
    }

    void enqueue(TaskRef task) @system
    {
        synchronized (mutex)
        {
            assert(!closing && pending < ValueCapacity);
            inbox[(head + pending) % ValueCapacity] = task;
            ++pending;
            ++accepted;
            workReady.notify();
        }
    }

    void closeAndJoin() @system
    {
        synchronized (mutex)
        {
            assert(!joined);
            closing = true;
            workReady.notifyAll();
        }
        // join() defaults to rethrow=true and would leave later workers
        // unjoined if one earlier worker terminated with a Throwable.
        // join(false) waits first and defers propagation until all have joined.
        Throwable firstWorkerFailure;
        foreach (i; 0 .. started)
        {
            Throwable failure;
            try
            {
                version (M1P07JoinFault)
                {
                    // Simulates Thread.join(false) throwing, but deliberately
                    // does NOT invoke undefined native join behaviour.
                    if (i == 0)
                        throw new ThreadException(
                            "P07 synthetic native join failure");
                }
                failure = workers[i].join(false);
            }
            catch (Throwable joinProblem)
            {
                version (M1P07FailStop)
                {
                    // A join failure does NOT establish target quiescence.
                    // Aborting prevents stack records from being destroyed
                    // while an unjoined worker might still hold TaskRefs.
                    p07FailStop("P07_FAILSTOP_JOIN\n".ptr);
                }
                else
                    throw joinProblem;
            }
            version (M1P06Start)
                ++confirmedJoins;
            if (failure !is null && firstWorkerFailure is null)
                firstWorkerFailure = failure;
        }

        version (M1P06Fatal)
        {
            p06LastJoined = started;
            p06LastAccepted = accepted;
            p06LastCompleted = completed;
            p06LastPending = pending;
        }
        synchronized (mutex)
        {
            // A fatal worker Error can abort the current task before its
            // ordinary completion counter is updated, and all surviving
            // workers might exit without draining a queue. This is failure,
            // not a successful result. The lifetime barrier is the join of
            // ALL started workers, not the counters.
            if (firstWorkerFailure is null)
            {
                assert(pending == 0);
                assert(accepted == completed);
            }
            joined = true;
        }
        if (firstWorkerFailure !is null)
            throw firstWorkerFailure;
    }

    private void workerLoop() @system
    {
        while (true)
        {
            TaskRef task;
            synchronized (mutex)
            {
                while (pending == 0 && !closing)
                    workReady.wait();
                if (pending == 0 && closing)
                    return;

                task = inbox[head];
                head = (head + 1) % ValueCapacity;
                --pending;
            }

            // Count normally returned work. Error unwinding may bypass
            // expected accounting; never infer task success or record
            // lifetime from this counter on a fatal worker exit.
            // closeAndJoin() uses actual native joins as its barrier.
            scope(exit)
            {
                synchronized (mutex)
                    ++completed;
            }
            dispatchTask(task);
            // No further record access after dispatch. Thread.join, rather
            // than the counter or result cell, is the quiescence barrier.
        }
    }
}

/++
 Constrained manual trust boundary: only a by-value array of primitive ints,
 a bounded count and a strongly pure, @safe, nothrow, @nogc function pointer
 cross this helper. There is no captured user context or borrow to outlive
 the wrapper. All record addresses are pinned in this call and threads
 have returned before any local record is destroyed. Each job writes its
 own record.result; the caller reads only after joining. Partial thread
 start and publication unwind through closeAndJoin. Fatal Errors are not
 generally recoverable, and this prototype is not a production proof.
+/
// Test-only fault injection is NOT built into the ordinary P04/P05 consumer.
// The producer alone reads this hook, never a worker; it tests whether an
// exception after accepting some tasks still closes and joins every worker.
version (M1P05Fault)
    private size_t faultBeforeEnqueue = size_t.max;

private ScalarBatchResult executeCopied(
    int[ValueCapacity] inputs,
    size_t count,
    ScalarOperation operation) @trusted
{
    // Defence in depth: the @trusted bridge validates its own complete
    // preconditions, rather than relying only on evaluateScalars().
    if (count < 2 || count > ValueCapacity || operation is null)
        throw new Exception("P05 invalid trusted dispatch arguments");

    ScalarBatchResult answer;
    answer.count = count;
    Record[ValueCapacity] records;
    foreach (i; 0 .. count)
        records[i].prepare(operation, inputs[i]);

    auto batch = new WorkerBatch();
    batch.start();
    try
    {
        foreach (i; 0 .. count)
        {
            version (M1P05Fault)
            {
                if (i == faultBeforeEnqueue)
                    throw new Exception("P05 injected enqueue failure");
            }
            batch.enqueue(records[i].reference());
        }
    }
    finally
        batch.closeAndJoin();

    foreach (i; 0 .. count)
        answer.values[i] = records[i].result;
    return answer;
}

/++
 Narrow @safe consumer envelope. All external input indirections are read
 synchronously and copied into an inline primitive array BEFORE spawning
 any worker. A scalar function pointer cannot carry a D delegate context;
 strong purity and the no-throw/no-GC annotations constrain its behavior.

 This deliberately does not accept arbitrary delegates or TaskScope borrows.
+/
ScalarBatchResult evaluateScalars(
    scope const(int)[] inputs,
    ScalarOperation operation) @safe
{
    if (inputs.length > ValueCapacity)
        throw new Exception("P04 capacity exceeded");
    if (operation is null)
        throw new Exception("P04 null operation");

    int[ValueCapacity] snapshot;
    foreach (i, value; inputs)
        snapshot[i] = value;

    // P05: zero/singleton work is performed entirely in compiler-checked
    // @safe code: no worker, cast, handoff or @trusted dispatcher needed.
    if (inputs.length == 0)
        return ScalarBatchResult.init;

    if (inputs.length == 1)
    {
        ScalarBatchResult answer;
        answer.count = 1;
        answer.values[0] = operation(snapshot[0]);
        return answer;
    }

    return executeCopied(snapshot, inputs.length, operation);
}


// P05: exercise the defensive trusted-dispatch guards through same-module
// compile-gated tests. None of these calls may start a worker or publish a
// TaskRef; every invalid count/callback is rejected before construction.
private int p05Identity(int value) @safe pure nothrow @nogc
{
    return value;
}

unittest
{
    int[ValueCapacity] data;
    foreach (invalidCount; [0, 1, ValueCapacity + 1])
    {
        bool rejected;
        try
            executeCopied(data, invalidCount, &p05Identity);
        catch (Exception ex)
            rejected = ex.msg == "P05 invalid trusted dispatch arguments";
        assert(rejected, "invalid trusted entry count was not rejected");
    }

    ScalarOperation noOperation;
    bool nullRejected;
    try
        executeCopied(data, 2, noOperation);
    catch (Exception ex)
        nullRejected = ex.msg == "P05 invalid trusted dispatch arguments";
    assert(nullRejected, "null trusted operation was not rejected");
}


version (M1P05Fault)
unittest
{
    int[ValueCapacity] data = [2, 3, 5, 7, 11, 13, 17, 19];
    // Failure happens after 0, 1, or 3 published records. All accepted
    // jobs must run to completion and all workers must join before rethrow.
    foreach (faultIndex; [0, 1, 3])
    {
        faultBeforeEnqueue = faultIndex;
        bool injected;
        try
            executeCopied(data, 4, &p05Identity);
        catch (Exception ex)
            injected = ex.msg == "P05 injected enqueue failure";
        assert(injected, "injected failure did not unwind through join");
    }

    faultBeforeEnqueue = size_t.max;
    auto success = executeCopied(data, 4, &p05Identity);
    assert(success.count == 4);
    assert(success.values[0 .. 4] == data[0 .. 4]);
}


version (M1P06Start)
unittest
{
    // Injections before the FIRST, SECOND and after the SECOND start.
    // All successfully launched worker threads must be fully joined
    // before start() rethrows to the caller.
    foreach (beforeStart; 0 .. WorkerCount + 1)
    {
        auto batch = new WorkerBatch();
        batch.failBeforeStart = beforeStart;
        bool sawFailure;
        try
            batch.start();
        catch (Exception ex)
            sawFailure = ex.msg == "P06 injected pre-start failure";
        assert(sawFailure);
        assert(batch.started == beforeStart);
        assert(batch.confirmedJoins == beforeStart);
        assert(batch.joined);
        assert(batch.accepted == 0 && batch.completed == 0);
    }
}

version (M1P06Fatal)
unittest
{
    // Run this test in a SEPARATE test binary: the selected task throws
    // an Error (as opposed to an ordinary Exception) from the @safe
    // nothrow task thunk, reaching druntime Thread termination.
    // join(false) must return the Throwable only AFTER the full join.
    int[4] inputs = [10, int.min, 20, 30];
    bool caughtWorkerError;
    try
        evaluateScalars(inputs[], &p05Identity);
    catch (Error ex)
    {
        caughtWorkerError = true;
        // A joined failed task may not be counted as normally completed,
        // so only the join and admission counts are lifetime assertions.
    }
    assert(caughtWorkerError, "P06 worker Error did not propagate");
    assert(p06LastJoined == WorkerCount);
    assert(p06LastAccepted == inputs.length);
    assert(p06LastCompleted <= inputs.length);

    // Both workers can terminate with an Error while queued work remains.
    // It must be rejected as an unsuccessful batch, yet both threads must
    // still be joined before unwinding the stack records.
    int[4] fatalBoth = [int.min, int.min, 7, 9];
    bool caughtDoubleError;
    try
        evaluateScalars(fatalBoth[], &p05Identity);
    catch (Error ex)
        caughtDoubleError = true;
    assert(caughtDoubleError);
    assert(p06LastJoined == WorkerCount);
    assert(p06LastAccepted == fatalBoth.length);
    assert(p06LastCompleted <= fatalBoth.length);
    assert(p06LastPending == 2,
        "two failing workers must leave the final two queued tasks unrun");

    // A successful fresh call checks that the failed scope did not leave
    // active users of its former stack records.
    int[2] next = [7, 9];
    auto after = evaluateScalars(next[], &p05Identity);
    assert(after.count == 2 && after.values[0] == 7 && after.values[1] == 9);
}


version (M1P07JoinFault)
unittest
{
    // The native start succeeds; the research hook then simulates an
    // exceptional return from join(false) while worker threads are alive.
    // M1P07FailStop MUST terminate this process; returning is failure.
    int[4] values = [2, 3, 5, 7];
    evaluateScalars(values[], &p05Identity);
    assert(0, "P07 returned after uncertain native join");
}

version (M1P07StartFault)
unittest
{
    // Native first start succeeds, but this research hook simulates an
    // exception before its handle is registered by the caller.
    // The only qualified behavior is fail-stop, not caller-stack unwind.
    int[4] values = [2, 3, 5, 7];
    evaluateScalars(values[], &p05Identity);
    assert(0, "P07 returned after uncertain native start");
}
