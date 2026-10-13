// EXPECT COMPILE FAILURE: closure context is not an accepted ScalarOperation.
// This is intentionally an external consumer of the real P04 module.
module negative_captured_delegate;

import concurrency.research.m1_value_scope : evaluateScalars;
alias BorrowedDelegate = int delegate(int) @safe pure nothrow @nogc;

void illegal(scope const(int)[] input, BorrowedDelegate callback) @safe
{
    auto result = evaluateScalars(input, callback);
}
