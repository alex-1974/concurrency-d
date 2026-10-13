// A real @safe consumer compiles and runs through the P04 typed interface.
module positive_safe_consumer;

import concurrency.research.m1_value_scope :
    evaluateScalars, ScalarBatchResult, ValueCapacity;
import std.stdio : writeln;

private int twice(int n) @safe pure nothrow @nogc
{
    return n * 2;
}

private void safeConsumer() @safe
{
    int[4] inputs = [1, 2, 4, 8];
    auto result = evaluateScalars(inputs[], &twice);
    assert(result.count == 4);
    assert(result.values[0 .. 4] == [2, 4, 8, 16]);
    // Repeated scopes must not retain any TaskRef to the old stack frame.
    foreach (round; 0 .. 32)
    {
        auto again = evaluateScalars(inputs[], &twice);
        assert(again.count == 4);
        assert(again.values[0 .. 4] == [2, 4, 8, 16]);
    }
    int[0] empty;
    assert(evaluateScalars(empty[], &twice).count == 0);

    int[ValueCapacity + 1] tooMany;
    bool rejected;
    try
        evaluateScalars(tooMany[], &twice);
    catch (Exception ex)
        rejected = ex.msg == "P04 capacity exceeded";
    assert(rejected);

    int function(int) @safe pure nothrow @nogc absent;
    bool nullRejected;
    try
        evaluateScalars(inputs[], absent);
    catch (Exception ex)
        nullRejected = ex.msg == "P04 null operation";
    assert(nullRejected);
}

void main()
{
    safeConsumer();
    writeln("P04 safe scalar consumer: PASS (safe entry, copy, 32 cycles, rejection)");
}
