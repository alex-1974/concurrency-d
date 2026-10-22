module positive_typed_consumer;

import concurrency.research.m1_typed_transport :
    TypedCapacity, InlineResults, evaluateInline;
import std.stdio : writeln;

private struct Point2 { int x; int y; }
private struct Cell { long total; int witness; }
private struct Nested { Point2[2] vertices; ushort[3] flags; }

private Cell project(Point2 p) @safe pure nothrow @nogc
{
    return Cell(cast(long)p.x * 10 + p.y, p.y);
}

private long sumNested(Nested arg) @safe pure nothrow @nogc
{
    return cast(long)arg.vertices[0].x + arg.vertices[0].y
        + arg.vertices[1].x + arg.vertices[1].y
        + arg.flags[0] + arg.flags[1] + arg.flags[2];
}

private int plusSeven(int value) @safe pure nothrow @nogc
{
    return value + 7;
}

private void safeConsumer() @safe
{
    Point2[4] points = [
        Point2(2, 3), Point2(4, 5),
        Point2(-3, 8), Point2(7, -9)
    ];
    auto projected = evaluateInline(points[], &project);
    assert(projected.count == 4);
    assert(projected.values[0].total == 23);
    assert(projected.values[1].total == 45);
    assert(projected.values[2].total == -22);
    assert(projected.values[3].total == 61);
    assert(projected.values[2].witness == 8);

    // Reuse independent scopes, including a full 8-record worker batch.
    int[TypedCapacity] full = [1, 2, 3, 4, 5, 6, 7, 8];
    foreach (cycle; 0 .. 32)
    {
        auto results = evaluateInline(full[], &plusSeven);
        assert(results.count == TypedCapacity);
        foreach (i; 0 .. TypedCapacity)
            assert(results.values[i] == full[i] + 7);
    }

    Nested[2] tiles;
    tiles[0] = Nested(
        [Point2(10, 20), Point2(30, 40)], [1, 2, 3]);
    tiles[1] = Nested(
        [Point2(-1, -2), Point2(3, 4)], [5, 6, 7]);
    auto nested = evaluateInline(tiles[], &sumNested);
    assert(nested.count == 2);
    assert(nested.values[0] == 106);
    assert(nested.values[1] == 22);

    // Only typed by-value data flows to the worker; input may be mutated
    // after the synchronous call returns without changing prior results.
    tiles[0].vertices[0].x = 999;
    assert(nested.values[0] == 106);

    // Pure @safe singleton and empty calls never create a worker.
    int[1] one = [15];
    assert(evaluateInline(one[], &plusSeven).values[0] == 22);
    int[] none;
    assert(evaluateInline(none, &plusSeven).count == 0);

    int[TypedCapacity + 1] oversized;
    bool rejected;
    try
        evaluateInline(oversized[], &plusSeven);
    catch (Exception error)
        rejected = error.msg == "P10 capacity exceeded";
    assert(rejected);

    int function(int) @safe pure nothrow @nogc absent;
    bool rejectedNull;
    try
        evaluateInline(one[], absent);
    catch (Exception error)
        rejectedNull = error.msg == "P10 null operation";
    assert(rejectedNull);
}

void main()
{
    safeConsumer();
    writeln("P10 typed TaskRef consumer: PASS (@safe POD P/R, ",
        "nested arrays, 32x8 workers, singleton, empty, rejects)");
}
