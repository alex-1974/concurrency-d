module negative_borrowed_member;
import concurrency.research.m1_inline_transfer : snapshotInline;
struct HiddenBorrow { const(int)* ptr; int tag; }
void invalid(HiddenBorrow work) @safe
{
    auto bad = snapshotInline(work);
}
