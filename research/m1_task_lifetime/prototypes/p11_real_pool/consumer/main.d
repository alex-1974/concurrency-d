/++
 P11 explicit @system research consumer. No @safe claim for native pool
 lifecycle, despite type-safe inline data and typed operation callbacks.
+/
module concurrency.research.p11_consumer;

import concurrency.research.m1_real_pool :
    evaluateWithRealPool, RealPoolCapacity;
import concurrency.internal.owned_task :
    OwnedTaskExecutor, TaskHandle;
import concurrency.research.m1_steal_probe : qualifyRealSteal;
import std.stdio : writeln;

private void requireP11(bool valid)
{
    if (!valid)
        throw new Exception("P11 consumer invariant failed");
}

private struct Point2
{
    int x;
    int y;
}

private struct Cell
{
    long value;
    int token;
}

private struct Tile
{
    Point2[2] vertices;
    ushort[3] flags;
}

private int calculate(int value) @safe pure nothrow @nogc
{
    // Enough arithmetic for identical computation in both M0 consumers,
    // without relying on a timing or work-stealing fairness claim.
    int result = value;
    foreach (i; 0 .. 32)
        result = (result * 17 + i) ^ (result >>> 3);
    return result;
}

private Cell mapPoint(Point2 p) @safe pure nothrow @nogc
{
    return Cell(cast(long)p.x * 10 + p.y, p.y);
}

private long sumTile(Tile tile) @safe pure nothrow @nogc
{
    return cast(long)tile.vertices[0].x + tile.vertices[0].y
        + tile.vertices[1].x + tile.vertices[1].y
        + tile.flags[0] + tile.flags[1] + tile.flags[2];
}

/++ Same scalar work, but independently submitted via actual M0 OwnedNode. +/
private struct OwnedCallable
{
    int input;
    int opCall()
    {
        return calculate(input);
    }
}

private void testBoundedTyped()
{
    int[RealPoolCapacity] full;
    foreach (i; 0 .. RealPoolCapacity)
        full[i] = cast(int)i * 3 - 300;

    foreach (workers; [1, 2, 4])
    {
        auto result = evaluateWithRealPool(full[], &calculate, workers, 4);
        requireP11(result.count == full.length);
        requireP11(result.accepted == full.length);
        requireP11(result.completed == full.length);
        requireP11(result.returned == full.length);

        foreach (i, raw; full)
            requireP11(result.values[i] == calculate(raw));
    }

    // Repeated calls prove stack record arrays from prior invocations are
    // not subsequently read by successfully joined pool workers.
    foreach (_; 0 .. 16)
    {
        auto result = evaluateWithRealPool(full[0 .. 16], &calculate, 4, 2);
        requireP11(result.accepted == 16);
        requireP11(result.completed == 16);
        requireP11(result.returned == 16);
        requireP11(result.values[15] == calculate(full[15]));
    }

    Point2[4] points = [
        Point2(2, 3), Point2(4, 5),
        Point2(-3, 8), Point2(7, -9)
    ];
    auto mapped = evaluateWithRealPool(points[], &mapPoint, 2, 2);
    requireP11(mapped.values[0].value == 23);
    requireP11(mapped.values[1].value == 45);
    requireP11(mapped.values[2].value == -22);
    requireP11(mapped.values[3].value == 61);
    requireP11(mapped.values[2].token == 8);

    Tile[2] tiles;
    tiles[0] = Tile(
        [Point2(10, 20), Point2(30, 40)], [1, 2, 3]);
    tiles[1] = Tile(
        [Point2(-1, -2), Point2(3, 4)], [5, 6, 7]);
    auto nested = evaluateWithRealPool(tiles[], &sumTile, 2, 1);
    requireP11(nested.values[0] == 106);
    requireP11(nested.values[1] == 22);
    tiles[0].vertices[0].x = 999;
    requireP11(nested.values[0] == 106);

    int[] empty;
    requireP11(evaluateWithRealPool(empty, &calculate).count == 0);

    int[RealPoolCapacity + 1] oversized;
    bool overRejected;
    try
        evaluateWithRealPool(oversized[], &calculate);
    catch (Exception error)
        overRejected = error.msg == "P11 too many values";
    requireP11(overRejected);

    bool zeroWorkersRejected;
    try
        evaluateWithRealPool(full[0 .. 1], &calculate, 0, 4);
    catch (Exception error)
        zeroWorkersRejected = error.msg == "P11 invalid pool shape";
    requireP11(zeroWorkersRejected);

    int function(int) @safe pure nothrow @nogc absent;
    bool nullRejected;
    try
        evaluateWithRealPool(full[0 .. 1], absent);
    catch (Exception error)
        nullRejected = error.msg == "P11 null operation";
    requireP11(nullRejected);
}

private void testActualOwnedExecutorParity()
{
    // SAME existing SubmissionWorkerPool transport. Different observable
    // result-handle and lifetime semantics => correctness parity ONLY.
    int[RealPoolCapacity] input;
    foreach (i; 0 .. input.length)
        input[i] = cast(int)i * 3 - 300;

    auto typed = evaluateWithRealPool(input[], &calculate, 4, 4);
    auto executor = new OwnedTaskExecutor(4, 4, RealPoolCapacity);

    TaskHandle!int[RealPoolCapacity] handles;
    foreach (i, value; input)
    {
        OwnedCallable job;
        job.input = value;
        handles[i] = executor.submit(job);
    }

    foreach (i; 0 .. handles.length)
    {
        requireP11(handles[i].get() == typed.values[i]);
        handles[i] = null;
    }

    executor.closeAndJoin();
    requireP11(executor.acceptedCount() == input.length);
    requireP11(executor.completedCount() == input.length);
}

void main()
{
    testBoundedTyped();
    testActualOwnedExecutorParity();
    qualifyRealSteal();
    writeln("P11 real M0 work stealing: PASS (typed P/R, 1/2/4 workers, ",
        "bounded backpressure, 16 scopes, owned parity, seven real steals)");
}
