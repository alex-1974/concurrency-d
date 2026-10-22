// EXPECT COMPILE FAILURE: typed op must be pure.
module negative_nonpure_operation;
import concurrency.research.m1_typed_transport : evaluateInline;

private int nonpure(int a) @safe nothrow @nogc { return a; }
void invalid(int[2] inputs) @safe
{
    auto result = evaluateInline(inputs[], &nonpure);
}
