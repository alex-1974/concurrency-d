// EXPECT COMPILE FAILURE: typed op must be @safe.
module negative_unsafe_operation;
import concurrency.research.m1_typed_transport : evaluateInline;

private int unsafeOp(int a) @system pure nothrow @nogc { return a; }
void invalid(int[2] inputs) @safe
{
    auto result = evaluateInline(inputs[], &unsafeOp);
}
