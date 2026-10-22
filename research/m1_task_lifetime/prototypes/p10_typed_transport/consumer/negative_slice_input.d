// EXPECT COMPILE FAILURE: slice is not a transferable payload.
module negative_slice_input;
import concurrency.research.m1_typed_transport : evaluateInline;

private int get(int[] input) @safe pure nothrow @nogc { return cast(int)input.length; }
void invalid(int[][2] inputs) @safe
{
    auto result = evaluateInline(inputs[], &get);
}
