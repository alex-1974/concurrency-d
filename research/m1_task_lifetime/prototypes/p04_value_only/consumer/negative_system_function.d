// EXPECT COMPILE FAILURE: a @system function pointer is not safe operation.
module negative_system_function;

import concurrency.research.m1_value_scope : evaluateScalars;

private int unsafeCompute(int value) @system pure nothrow @nogc
{
    return value + 1;
}

void illegal(scope const(int)[] input) @safe
{
    auto result = evaluateScalars(input, &unsafeCompute);
}
