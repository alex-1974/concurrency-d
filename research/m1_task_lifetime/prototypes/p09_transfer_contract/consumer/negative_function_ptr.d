module negative_function_ptr;
import concurrency.research.m1_inline_transfer : snapshotInline;
alias NoCapture = int function(int) @safe nothrow @nogc;
void invalid(NoCapture callable) @safe
{
    auto bad = snapshotInline(callable);
}
