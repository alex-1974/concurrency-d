// Explicitly @safe external consumer of the real P09 research module.
module positive_inline_consumer;

import concurrency.research.m1_inline_transfer :
    isInlineTransfer, snapshotInline;
import std.stdio : writeln;

struct Pixel
{
    ushort r, g, b;
}

struct Tile
{
    Pixel[2] row;
    int[3] position;
}

struct BorrowedPointer { int* p; }
struct BorrowedSlice { immutable(char)[] name; }
struct CallableCapture { int delegate() dg; }
struct Nontrivial
{
    int value;
    ~this() {}
}
class ObjectPayload { int x; }

static assert(isInlineTransfer!int);
static assert(isInlineTransfer!(int[4]));
static assert(isInlineTransfer!Pixel);
static assert(isInlineTransfer!Tile);
static assert(!isInlineTransfer!(int*));
static assert(!isInlineTransfer!(int[]));
static assert(!isInlineTransfer!BorrowedPointer);
static assert(!isInlineTransfer!BorrowedSlice);
static assert(!isInlineTransfer!CallableCapture);
static assert(!isInlineTransfer!Nontrivial);
static assert(!isInlineTransfer!ObjectPayload);
static assert(!isInlineTransfer!(void delegate()));

private void checkSafeConsumer() @safe
{
    auto original = Tile(
        [Pixel(1, 2, 3), Pixel(4, 5, 6)],
        [10, 20, 30]);
    auto copied = snapshotInline(original);
    original.row[0].r = 999;
    original.position[0] = -7;

    assert(copied.row[0].r == 1);
    assert(copied.row[1].g == 5);
    assert(copied.position == [10, 20, 30]);
    int[4] array = [3, 5, 7, 11];
    auto snapshot = snapshotInline(array);
    array[0] = 101;
    assert(snapshot[0] == 3);
    assert(snapshotInline(19) == 19);
}

void main()
{
    checkSafeConsumer();
    writeln("P09 inline value consumer: PASS (nested POD, copied arrays, @safe)");
}
