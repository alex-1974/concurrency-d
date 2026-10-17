/++
 M1 P25 research only: compare lexical LifetimeToken with process registry
 for the same SOURCE-PINNED real M0 OwnedTaskExecutor and TaskRef workers.

 Token cannot be copied; leaving its scope before a real successful native
 join is fail-stop. A registry can remain reachable across handle loss.
 Both use GC.addRoot/removeRoot. No generic @safe or native retry claim.
+/
module concurrency.research.p25_ownership_modes;

import concurrency.research.m1_p23_owned : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.memory : GC;
import core.stdc.stdio : fprintf, fflush, stderr;
import core.stdc.stdlib : abort;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;
import std.algorithm.mutation : move;

private void require(bool yes, string why)
{
    if (!yes)
        throw new Exception("P25: " ~ why);
}

private struct LifetimeToken
{
    private OwnedTaskExecutor owner;
    private bool registered;

    @disable this(this);

    // Must be adopted before the P23 explicit native start.
    void adopt(OwnedTaskExecutor incoming) @system
    {
        require(!registered && incoming !is null &&
            incoming.researchConstructed(), "token prelaunch adoption");
        GC.addRoot(cast(void*) incoming);
        owner = incoming;
        registered = true;
    }

    OwnedTaskExecutor borrow()
    {
        require(registered && owner !is null, "inactive token access");
        return owner;
    }

    void start() @system { borrow().researchStart(); }

    bool tryRelease() @system
    {
        if (!registered)
            return false;
        if (!owner.isStopped())
            return false;
        require(owner.retainedCount() == 0, "token joined roots remain");
        GC.removeRoot(cast(void*) owner);
        owner = null;
        registered = false;
        return true;
    }

    // A token is an explicit *scoped* owner, not an independently
    // abandoned executor. No implicit detach or failed-join retry.
    ~this() @system nothrow
    {
        if (registered)
        {
            fprintf(stderr, "P25_TOKEN_DROP_FAILSTOP\n");
            fflush(stderr);
            abort();
        }
    }
}

private final class ProcessRegistry
{
    private Mutex mutex;
    private OwnedTaskExecutor owner;

    this() { mutex = new Mutex(); }

    void adopt(OwnedTaskExecutor incoming) @system
    {
        require(incoming !is null && incoming.researchConstructed(),
            "registry prelaunch adoption");
        synchronized (mutex)
        {
            require(owner is null, "registry slot already occupied");
            GC.addRoot(cast(void*) incoming);
            owner = incoming;
        }
    }

    OwnedTaskExecutor borrow()
    {
        synchronized (mutex)
        {
            require(owner !is null, "empty process root");
            return owner;
        }
    }

    void start() @system { borrow().researchStart(); }

    bool tryRelease() @system
    {
        synchronized (mutex)
        {
            if (owner is null || !owner.isStopped())
                return false;
            require(owner.retainedCount() == 0, "registry joined roots remain");
            GC.removeRoot(cast(void*) owner);
            owner = null;
            return true;
        }
    }

    bool holds()
    {
        synchronized (mutex)
            return owner !is null;
    }

    // P26: a borrowed LOCAL reference is acquired under the same
    // mutex as root removal. Null is an expected race outcome.
    OwnedTaskExecutor tryBorrow()
    {
        synchronized (mutex)
            return owner;
    }
}

private __gshared ProcessRegistry globalRegistry;

private ProcessRegistry registry()
{
    require(globalRegistry !is null, "process registry absent");
    return globalRegistry;
}

private final class Gate
{
    Semaphore sem;
    shared uint entered;
    this() { sem = new Semaphore(0); }
    void park()
    {
        atomicFetchAdd!(MemoryOrder.rel)(entered, 1u);
        sem.wait();
    }
    void openOrAbort()
    {
        try sem.notify();
        catch (Throwable) abort();
    }
}

private final class Graph
{
    int value;
    Graph child;
    this(int n, Graph next = null) { value = n; child = next; }
}

private final class Receipt
{
    shared uint count;
    shared uint sum;
}

private struct Work
{
    Gate gate;
    Graph graph;
    Receipt receipt;
    int opCall()
    {
        gate.park();
        const answer = cast(uint)(graph.value + graph.child.value * 3);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.sum, answer);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.count, 1u);
        return cast(int)answer;
    }
}

private enum Mode : ubyte { token, registry }

private OwnedTaskExecutor borrow(Mode mode, ref LifetimeToken token)
{
    return mode == Mode.token ? token.borrow() : registry().borrow();
}

private bool release(Mode mode, ref LifetimeToken token) @system
{
    return mode == Mode.token ? token.tryRelease() : registry().tryRelease();
}

private void parkUntilWorker(Gate gate)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entered) == 0u)
    {
        require(MonoTime.currTime < deadline, "real worker did not park");
        Thread.yield();
    }
}

private void inspectBlocked(Mode mode, ref LifetimeToken token)
{
    foreach (_; 0 .. 4)
    {
        GC.collect();
        auto owner = borrow(mode, token);
        require(owner.acceptedCount() == 1 && owner.completedCount() == 0,
            "blocked task changed accepted/completed obligation");
        require(owner.retainedCount() == 1, "owned record lost under GC");
        require(!release(mode, token), "unjoined owner released");
    }
}

private void verifyJoined(Mode mode, ref LifetimeToken token,
    Receipt receipt, uint answer)
{
    auto executor = borrow(mode, token);
    require(executor.isStopped(), "native join not proven");
    require(executor.acceptedCount() == 1 &&
        executor.completedCount() == 1 &&
        executor.retainedCount() == 0, "real M0 accounting changed");
    require(atomicLoad!(MemoryOrder.acq)(receipt.count) == 1u &&
        atomicLoad!(MemoryOrder.acq)(receipt.sum) == answer,
        "real M0 task result incorrect");
    require(release(mode, token), "joined root not released");
    require(!release(mode, token), "double-root removal accepted");
}

private Thread faultCloser(OwnedTaskExecutor executor, shared uint* failures)
{
    return new Thread({
        try executor.closeAndJoin();
        catch (Exception error)
        {
            if (error.msg != "P23 synthetic before-native-join")
                throw error;
            atomicFetchAdd!(MemoryOrder.rel)(*failures, 1u);
        }
    });
}

private void joinOrAbort(Thread t)
{
    try
    {
        auto error = t.join(false);
        if (error !is null)
            abort();
    }
    catch (Throwable)
        abort();
}

// Both modes execute exactly the same actual OwnedNode/M0 task semantics.
private void exercise(Mode mode, bool synthetic)
{
    LifetimeToken token;
    auto controller = new OwnedTaskExecutor(1, 4, 4);
    if (mode == Mode.token)
        token.adopt(controller);
    else
        registry().adopt(controller);
    require(controller.researchConstructed(),
        "native pool started before owner registration");
    controller = null;

    if (mode == Mode.token)
        token.start();
    else
        registry().start();

    auto gate = new Gate();
    auto receipt = new Receipt();
    Work work;
    work.gate = gate;
    work.graph = new Graph(7, new Graph(11));
    work.receipt = receipt;
    {
        auto owner = borrow(mode, token);
        auto result = owner.submit(work);
        require(result !is null, "admission failed on original M0");
        result = null;
    }
    parkUntilWorker(gate);
    inspectBlocked(mode, token);

    if (synthetic)
    {
        auto beforeNativeJoin = new Semaphore(0);
        borrow(mode, token).researchInjectPreJoin(beforeNativeJoin);
        shared uint failures;
        auto closer = faultCloser(borrow(mode, token), &failures);
        try closer.start();
        catch (Throwable) abort();

        const deadline = MonoTime.currTime + dur!"seconds"(10);
        while (borrow(mode, token).researchJoinClaims() != 1)
        {
            require(MonoTime.currTime < deadline,
                "fault closer failed to claim native join");
            Thread.yield();
        }
        require(!release(mode, token), "draining released owner");

        try beforeNativeJoin.notify();
        catch (Throwable) abort();
        joinOrAbort(closer);
        require(atomicLoad!(MemoryOrder.acq)(failures) == 1u &&
            borrow(mode, token).researchUncertain() &&
            !borrow(mode, token).isStopped(),
            "injected pre-native-join failure masked uncertainty");
        inspectBlocked(mode, token);

        gate.openOrAbort();
        // This is the FIRST actual native join, not a retry of an OS error.
        try borrow(mode, token).researchJoinKnownSynthetic();
        catch (Throwable) abort();
    }
    else
    {
        gate.openOrAbort();
        try borrow(mode, token).closeAndJoin();
        catch (Throwable) abort();
    }

    verifyJoined(mode, token, receipt, 40u);
    if (mode == Mode.registry)
        require(!registry().holds(), "process root survived verified join");
    // The token destructor is now permitted to return normally.
}

// P26: each thread captures a separate function activation, not a
// foreach iteration frame. These inspect only the fully joined owner.
private Thread p26Reader(ProcessRegistry reg, shared uint* seen)
{
    return new Thread({
        foreach (_; 0 .. 1000)
        {
            auto local = reg.tryBorrow();
            if (local !is null)
            {
                if (!local.isStopped() || local.retainedCount() != 0)
                    abort();
                atomicFetchAdd!(MemoryOrder.rel)(*seen, 1u);
            }
            Thread.yield();
        }
    });
}

private Thread p26Releaser(ProcessRegistry reg, shared uint* won)
{
    return new Thread({
        if (reg.tryRelease())
            atomicFetchAdd!(MemoryOrder.rel)(*won, 1u);
    });
}

private void p26Join(Thread t)
{
    try
    {
        auto failure = t.join(false);
        if (failure !is null)
            abort();
    }
    catch (Throwable)
        abort();
}

private void p26ConcurrentRegistry()
{
    foreach (_; 0 .. 12)
    {
        auto reg = new ProcessRegistry();
        auto owner = new OwnedTaskExecutor(1, 4, 4);
        reg.adopt(owner);
        owner = null;
        reg.start();
        reg.borrow().closeAndJoin(); // proof before root unregistration
        require(reg.borrow().isStopped(), "P26 prior join absent");

        shared uint observed, successes;
        Thread[4] readers;
        Thread[4] releasers;
        foreach (i; 0 .. readers.length)
        {
            readers[i] = p26Reader(reg, &observed);
            try readers[i].start();
            catch (Throwable) abort();
        }
        foreach (i; 0 .. releasers.length)
        {
            releasers[i] = p26Releaser(reg, &successes);
            try releasers[i].start();
            catch (Throwable) abort();
        }
        foreach (t; readers)
            p26Join(t);
        foreach (t; releasers)
            p26Join(t);
        require(atomicLoad!(MemoryOrder.acq)(successes) == 1u,
            "P26 registry must unregister exactly once");
        require(!reg.holds() && reg.tryBorrow() is null &&
            !reg.tryRelease(), "P26 registry stale/double release");
        GC.collect();
    }
}

private void p26MoveOwnership()
{
    LifetimeToken initial;
    auto owner = new OwnedTaskExecutor(1, 4, 4);
    initial.adopt(owner);
    owner = null;
    initial.start();
    // Deliberate D move primitive rather than accidental copy.
    auto relocated = move(initial);
    require(relocated.borrow() !is null, "P26 moved token lost owner");
    relocated.borrow().closeAndJoin();
    require(relocated.tryRelease(), "P26 moved token root not removed");
    require(!relocated.tryRelease(), "P26 duplicate root removal");
    // Both destructors must now complete without fail-stop.
}

private void p26CloseOrAbort(OwnedTaskExecutor executor)
{
    try executor.closeAndJoin();
    catch (Throwable) abort();
}

private void p26ExceptionWithJoinedCleanup()
{
    LifetimeToken token;
    auto owner = new OwnedTaskExecutor(1, 4, 4);
    token.adopt(owner);
    owner = null;
    token.start();
    try
        throw new Exception("P26_expected_unwind");
    finally
    {
        p26CloseOrAbort(token.borrow());
        require(token.tryRelease(), "P26 finally failed native join cleanup");
    }
}

private void p26Positive()
{
    foreach (_; 0 .. 12)
        p26MoveOwnership();
    foreach (_; 0 .. 12)
    {
        bool caught;
        try p26ExceptionWithJoinedCleanup();
        catch (Exception error)
            caught = error.msg == "P26_expected_unwind";
        require(caught, "P26 exception propagation changed by token");
    }
    p26ConcurrentRegistry();
    writeln("P26_OWNERSHIP_SAFETY_PASS moved=12 unwind=12 races=12");
}

version (P26ReturnCopy)
{
    private LifetimeToken p26BadReturn(ref LifetimeToken original)
    {
        return original; // requires prohibited copy, NOT move from lvalue
    }
}

version (P25NegativeCopy)
{
    void compileNegativeCopy()
    {
        LifetimeToken first;
        auto duplicate = first; // MUST fail: @disable this(this)
    }
}

version (P26UnwindFault)
{
    void main()
    {
        try
        {
            LifetimeToken token;
            auto owner = new OwnedTaskExecutor(1, 2, 2);
            token.adopt(owner);
            token.start();
            owner = null;
            import core.stdc.stdio : fprintf, fflush, stderr;
            fprintf(stderr, "P26_INJECTED_UNWIND\n");
            fflush(stderr);
            throw new Exception("P26_injected_scope_throw");
        }
        catch (Exception)
        {
            // Unreachable if the active token destructor fail-stops.
            writeln("P26_UNEXPECTED_RECOVERABLE_SCOPE");
        }
    }
}
else version (P25DropFault)
{
    void main()
    {
        LifetimeToken token;
        auto controller = new OwnedTaskExecutor(1, 2, 2);
        token.adopt(controller);
        token.start();
        controller = null;
        // The scope ends with a live native worker and an active root.
        // The destructor must fail-stop. The runner checks exit 134 AND
        // the distinct P25_TOKEN_DROP_FAILSTOP stderr marker.
    }
}
else
{
    void main()
    {
        globalRegistry = new ProcessRegistry();
        foreach (_; 0 .. 6)
        {
            exercise(Mode.token, false);
            exercise(Mode.registry, false);
            exercise(Mode.token, true);
            exercise(Mode.registry, true);
        }
        require(!registry().holds(), "registry was not emptied");
        version (P26Positive)
            p26Positive();
        writeln("P25_OWNER_MODES_PASS token=12 registry=12 normal=12 uncertain=12");
    }
}
