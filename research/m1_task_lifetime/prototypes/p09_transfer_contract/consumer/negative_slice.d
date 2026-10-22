module negative_slice;
import concurrency.research.m1_inline_transfer : snapshotInline;
void invalid(scope int[] values) @safe
{
    auto bad = snapshotInline(values);
}
