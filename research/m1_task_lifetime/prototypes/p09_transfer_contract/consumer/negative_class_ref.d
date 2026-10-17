module negative_class_ref;
import concurrency.research.m1_inline_transfer : snapshotInline;
class Payload { int x; }
void invalid(Payload object) @safe
{
    auto bad = snapshotInline(object);
}
