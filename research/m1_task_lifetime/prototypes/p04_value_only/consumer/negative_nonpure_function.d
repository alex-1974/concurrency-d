// EXPECT COMPILE FAILURE: a callback that is not pure is not accepted.
module negative_nonpure_function;

import concurrency.research.m1_value_scope : evaluateScalars;

private int nonPure(int value) @safe nothrow @nogc
{
    return value + 1;
}

void illegal(scope const(int)[] input) @safe
{
    auto result = evaluateScalars(input, &nonPure);
}
