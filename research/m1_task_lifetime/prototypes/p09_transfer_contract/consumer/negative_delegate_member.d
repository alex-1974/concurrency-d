module negative_delegate_member;
import concurrency.research.m1_inline_transfer : snapshotInline;
struct CapturedWork { int delegate() callback; }
void invalid(CapturedWork work) @safe
{
    auto bad = snapshotInline(work);
}
