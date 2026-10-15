/++
 M1 P21: bounded explicit native-shutdown / root-retention contract model.
 RESEARCH ONLY, deliberately NOT the production pool or an @safe executor.
 It models proof *events*: nativeJoinProved means evidence is supplied by a
 separate successful OS join, NEVER a proposed retry after join failure.
+/
module concurrency.research.m1_p21_shutdown_contract;

import std.stdio : writeln;

private enum uint Capacity = 2;
private enum uint Workers = 2;

private enum Phase : ubyte
{
    running, draining, shutdownUncertain, joinedStopped
}

private enum Worker : ubyte
{
    absent, knownStarted, possiblyStarted, joinProven
}

private enum Event : ubyte
{
    startKnown,
    startMayHaveLaunched,
    admit,
    returnedAfterDispatch,
    requestClose,
    nativeJoinFailed,
    nativeJoinProved,
    certifiedNeverStarted,
    dropController,
    settleUnexecuted,
    releaseRoots
}

private struct Model
{
    Phase phase;
    Worker[Workers] workers;
    uint accepted;
    uint returned;
    uint canceled;
    bool controller;
    bool supervisor;
    bool rootsHeld;
}

private Model initial() @safe pure nothrow @nogc
{
    Model m;
    m.phase = Phase.running;
    m.controller = true;
    m.supervisor = true;
    m.rootsHeld = true;
    return m;
}

private bool allQuiescent(ref const Model m) @safe pure nothrow @nogc
{
    foreach (state; m.workers)
        if (state != Worker.absent && state != Worker.joinProven)
            return false;
    return true;
}

private bool mayHaveActiveWorker(ref const Model m)
    @safe pure nothrow @nogc
{
    foreach (state; m.workers)
        if (state == Worker.knownStarted ||
            state == Worker.possiblyStarted)
            return true;
    return false;
}

private bool valid(ref const Model m) @safe pure nothrow @nogc
{
    if (m.accepted > Capacity ||
        m.returned + m.canceled > m.accepted)
        return false;
    if (m.rootsHeld != m.supervisor)
        return false;
    if (!m.controller && !m.supervisor && m.rootsHeld)
        return false;
    if (m.phase == Phase.joinedStopped && !allQuiescent(m))
        return false;
    if (!m.rootsHeld &&
        (m.phase != Phase.joinedStopped ||
         m.accepted != m.returned + m.canceled))
        return false;
    if (m.phase == Phase.running && !m.rootsHeld)
        return false;
    return true;
}

private bool same(ref const Model a, ref const Model b)
    @safe pure nothrow @nogc
{
    if (a.phase != b.phase || a.accepted != b.accepted ||
        a.returned != b.returned || a.canceled != b.canceled ||
        a.controller != b.controller ||
        a.supervisor != b.supervisor ||
        a.rootsHeld != b.rootsHeld)
        return false;
    foreach (i; 0 .. Workers)
        if (a.workers[i] != b.workers[i])
            return false;
    return true;
}

/++
 Every rejected transition leaves the model untouched. The caller supplies
 externally proved join/never-started events; this code does NOT produce
 those OS-level facts or prove native-join retry safety.
+/
private bool step(ref Model m, Event event, uint index = 0)
    @safe pure nothrow @nogc
{
    if (!valid(m))
        return false;

    Model next = m;
    bool changed;
    final switch (event)
    {
        case Event.startKnown:
            if (index < Workers && next.phase == Phase.running &&
                next.workers[index] == Worker.absent)
            {
                next.workers[index] = Worker.knownStarted;
                changed = true;
            }
            break;
        case Event.startMayHaveLaunched:
            if (index < Workers && next.phase == Phase.running &&
                next.workers[index] == Worker.absent)
            {
                next.workers[index] = Worker.possiblyStarted;
                // Admission must be closed when post-launch startup
                // status becomes ambiguous.
                next.phase = Phase.shutdownUncertain;
                changed = true;
            }
            break;
        case Event.admit:
            if (next.phase == Phase.running && next.rootsHeld &&
                next.accepted < Capacity && mayHaveActiveWorker(next))
            {
                ++next.accepted;
                changed = true;
            }
            break;
        case Event.returnedAfterDispatch:
            if (next.phase != Phase.joinedStopped &&
                next.returned < next.accepted &&
                mayHaveActiveWorker(next))
            {
                ++next.returned;
                changed = true;
            }
            break;
        case Event.requestClose:
            if (next.phase == Phase.running)
            {
                next.phase = allQuiescent(next)
                    ? Phase.joinedStopped : Phase.draining;
                changed = true;
            }
            break;
        case Event.nativeJoinFailed:
            if (next.phase == Phase.draining &&
                mayHaveActiveWorker(next))
            {
                next.phase = Phase.shutdownUncertain;
                changed = true;
            }
            break;
        case Event.nativeJoinProved:
            if (index < Workers &&
                (next.phase == Phase.draining ||
                 next.phase == Phase.shutdownUncertain) &&
                (next.workers[index] == Worker.knownStarted ||
                 next.workers[index] == Worker.possiblyStarted))
            {
                next.workers[index] = Worker.joinProven;
                if (allQuiescent(next))
                    next.phase = Phase.joinedStopped;
                changed = true;
            }
            break;
        case Event.certifiedNeverStarted:
            if (index < Workers &&
                next.phase == Phase.shutdownUncertain &&
                next.workers[index] == Worker.possiblyStarted)
            {
                // Only a trustworthy external no-start certificate may
                // discharge this possible-native-worker obligation.
                next.workers[index] = Worker.absent;
                if (allQuiescent(next))
                    next.phase = Phase.joinedStopped;
                changed = true;
            }
            break;
        case Event.dropController:
            if (next.controller && next.supervisor)
            {
                next.controller = false;
                changed = true;
            }
            break;
        case Event.settleUnexecuted:
            if (next.phase == Phase.joinedStopped &&
                next.returned + next.canceled < next.accepted)
            {
                ++next.canceled;
                changed = true;
            }
            break;
        case Event.releaseRoots:
            if (next.phase == Phase.joinedStopped &&
                allQuiescent(next) && next.supervisor &&
                next.returned + next.canceled == next.accepted)
            {
                next.rootsHeld = false;
                next.supervisor = false;
                changed = true;
            }
            break;
    }
    if (!changed || !valid(next))
        return false;

    m = next;
    return true;
}

private void require(bool condition, string reason)
{
    if (!condition)
        throw new Exception("P21 shutdown contract: " ~ reason);
}

private void requireEvent(ref Model m, Event event, uint index = 0)
{
    require(step(m, event, index), "required event rejected");
}

private void requireRejected(ref Model m, Event event, uint index = 0)
{
    auto before = m;
    require(!step(m, event, index), "forbidden event accepted");
    require(same(m, before), "rejected event mutated state");
}

private void testJoinUncertainWithAbandonedController()
{
    auto model = initial();
    requireEvent(model, Event.startKnown);
    requireEvent(model, Event.admit);
    requireEvent(model, Event.requestClose);
    requireEvent(model, Event.nativeJoinFailed);
    require(model.phase == Phase.shutdownUncertain, "join failure state");
    requireEvent(model, Event.dropController);
    requireRejected(model, Event.releaseRoots);
    requireRejected(model, Event.admit);
    require(model.rootsHeld && model.supervisor && !model.controller,
        "independent roots required after abandonment");
    requireEvent(model, Event.returnedAfterDispatch);

    // A task-return marker is NOT proof of a native join.
    requireRejected(model, Event.releaseRoots);
    // This input represents a separately observed successful native join.
    requireEvent(model, Event.nativeJoinProved);
    require(model.phase == Phase.joinedStopped, "joined state missing");
    requireEvent(model, Event.releaseRoots);
    require(!model.rootsHeld, "roots not released at verified boundary");
}

private void testMultipleWorkersAndUnsettledWork()
{
    auto model = initial();
    requireEvent(model, Event.startKnown, 0);
    requireEvent(model, Event.startKnown, 1);
    requireEvent(model, Event.admit);
    requireEvent(model, Event.admit);
    requireEvent(model, Event.requestClose);
    requireEvent(model, Event.nativeJoinProved, 0);
    requireRejected(model, Event.releaseRoots);
    requireEvent(model, Event.nativeJoinFailed);
    requireEvent(model, Event.nativeJoinProved, 1);
    require(model.phase == Phase.joinedStopped, "both joins required");
    requireRejected(model, Event.releaseRoots);
    requireEvent(model, Event.settleUnexecuted);
    requireEvent(model, Event.settleUnexecuted);
    requireEvent(model, Event.releaseRoots);
    require(model.canceled == model.accepted && !model.supervisor,
        "unexecuted accepted tasks must be settled before release");
}

private void testAmbiguousPostLaunchStart()
{
    auto model = initial();
    requireEvent(model, Event.startMayHaveLaunched, 0);
    require(model.phase == Phase.shutdownUncertain, "start status");
    requireRejected(model, Event.requestClose);
    requireRejected(model, Event.releaseRoots);
    requireRejected(model, Event.admit);
    requireEvent(model, Event.dropController);
    requireRejected(model, Event.releaseRoots);
    // A verified no-launch certificate is distinct from a thrown start().
    requireEvent(model, Event.certifiedNeverStarted, 0);
    require(model.phase == Phase.joinedStopped, "no-launch proof missing");
    requireEvent(model, Event.releaseRoots);
}

private bool workerIndexed(Event event) @safe pure nothrow @nogc
{
    return event == Event.startKnown ||
        event == Event.startMayHaveLaunched ||
        event == Event.nativeJoinProved ||
        event == Event.certifiedNeverStarted;
}

private void explore(Model model, uint depth,
    ref ulong snapshots, ref ulong acceptedEdges, ref ulong deniedEdges)
{
    require(valid(model), "invalid reachable state");
    ++snapshots;
    if (depth == 0)
        return;

    foreach (eventCode; 0 .. cast(uint)Event.releaseRoots + 1)
    {
        auto event = cast(Event) eventCode;
        const indices = workerIndexed(event) ? Workers : 1u;
        foreach (index; 0 .. indices)
        {
            auto next = model;
            const accepted = step(next, event, index);
            require(valid(next), "transition produced invalid state");
            if (accepted)
            {
                ++acceptedEdges;
                explore(next, depth - 1, snapshots,
                    acceptedEdges, deniedEdges);
            }
            else
            {
                ++deniedEdges;
                require(same(next, model),
                    "rejected transition modified owner state");
            }
        }
    }
}

void main()
{
    testJoinUncertainWithAbandonedController();
    testMultipleWorkersAndUnsettledWork();
    testAmbiguousPostLaunchStart();
    ulong snapshots, acceptedEdges, deniedEdges;
    explore(initial(), 7, snapshots, acceptedEdges, deniedEdges);
    require(snapshots > 100 && acceptedEdges > 100 &&
        deniedEdges > 100, "inadequate transition coverage");
    writeln("P21_SHUTDOWN_CONTRACT_PASS states=", snapshots,
        " edges=", acceptedEdges, " rejects=", deniedEdges);
}
