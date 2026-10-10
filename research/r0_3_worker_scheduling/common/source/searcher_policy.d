module searcher_policy;

import core.atomic :
    MemoryOrder,
    atomicFetchSub,
    atomicLoad,
    cas;

enum SearcherPolicy
{
    all,
    one,
    bounded
}

const(char)[] searcherPolicyName(
    SearcherPolicy policy)
    @safe @nogc nothrow
{
    final switch (policy)
    {
        case SearcherPolicy.all:
            return "all";

        case SearcherPolicy.one:
            return "one";

        case SearcherPolicy.bounded:
            return "bounded";
    }
}

size_t searcherLimit(
    SearcherPolicy policy,
    size_t workerCount)
    @safe @nogc nothrow
{
    if (workerCount <= 1)
        return 0;

    final switch (policy)
    {
        case SearcherPolicy.all:
            return workerCount;

        case SearcherPolicy.one:
            return 1;

        case SearcherPolicy.bounded:
            return workerCount <= 2
                ? 1
                : (workerCount + 1) / 2;
    }
}

bool tryAcquireSearcher(
    SearcherPolicy policy,
    size_t workerCount,
    shared size_t* active)
    @safe @nogc nothrow
{
    if (policy == SearcherPolicy.all)
        return true;

    const limit =
        searcherLimit(
            policy,
            workerCount);

    for (;;)
    {
        const current =
            atomicLoad!(
                MemoryOrder.raw)(
                    *active);

        if (current >= limit)
            return false;

        if (
            cas!(
                MemoryOrder.acq,
                MemoryOrder.raw)(
                    active,
                    current,
                    current + 1))
        {
            return true;
        }
    }
}

void releaseSearcher(
    SearcherPolicy policy,
    shared size_t* active)
    @safe @nogc nothrow
{
    if (policy == SearcherPolicy.all)
        return;

    const previous =
        atomicFetchSub!(
            MemoryOrder.rel)(
                *active,
                1);

    assert(previous != 0);
}

unittest
{
    assert(
        searcherLimit(
            SearcherPolicy.all,
            4) == 4);

    assert(
        searcherLimit(
            SearcherPolicy.one,
            4) == 1);

    assert(
        searcherLimit(
            SearcherPolicy.bounded,
            4) == 2);

    assert(
        searcherLimit(
            SearcherPolicy.bounded,
            2) == 1);
}
