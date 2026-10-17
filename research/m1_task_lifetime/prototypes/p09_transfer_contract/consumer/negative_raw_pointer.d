// EXPECT REJECTION by the actual P09 constrained overload.
module negative_raw_pointer;
import concurrency.research.m1_inline_transfer : snapshotInline;
void invalid(int* pointer) @safe
{
    auto bad = snapshotInline(pointer);
}
