module layout;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_rmw :
    ModularRmwBoundedWorkStealingDeque;

import std.stdio : writefln;

alias Baseline =
    ModularBoundedWorkStealingDeque!(size_t, 8);

alias Rmw =
    ModularRmwBoundedWorkStealingDeque!(size_t, 8);

void main()
{
    Baseline baseline;
    Rmw rmw;

    writefln(
        "baseline.sizeof=%s alignof=%s",
        Baseline.sizeof,
        Baseline.alignof);

    writefln(
        "rmw.sizeof=%s alignof=%s",
        Rmw.sizeof,
        Rmw.alignof);

    version (ConcurrencyResearchProbe)
    {
        writefln(
            "baseline top=%s bottom=%s",
            cast(size_t)(
                cast(ubyte*)&baseline._top -
                cast(ubyte*)&baseline),
            cast(size_t)(
                cast(ubyte*)&baseline._bottom -
                cast(ubyte*)&baseline));

        writefln(
            "rmw top=%s bottom=%s fence=%s",
            cast(size_t)(
                cast(ubyte*)&rmw._top -
                cast(ubyte*)&rmw),
            cast(size_t)(
                cast(ubyte*)&rmw._bottom -
                cast(ubyte*)&rmw),
            cast(size_t)(
                cast(ubyte*)&rmw._fenceWord -
                cast(ubyte*)&rmw));
    }
}
