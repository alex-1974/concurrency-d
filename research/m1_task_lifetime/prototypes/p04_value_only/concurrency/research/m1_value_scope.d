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
    record.result = record.operation(record.argument);
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
                worker = new Thread({ workerLoop(); });
                worker.start();
                ++started;
            }
        }
        catch (Throwable problem)
        {
            closeAndJoin();
            throw problem;
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
        foreach (i; 0 .. started)
            workers[i].join();

        synchronized (mutex)
        {
            assert(pending == 0);
            assert(accepted == completed);
            joined = true;
        }
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

            dispatchTask(task);
            // No further record access after execution. Thread.join
            // establishes that all records are quiescent before they die.
            synchronized (mutex)
                ++completed;
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
