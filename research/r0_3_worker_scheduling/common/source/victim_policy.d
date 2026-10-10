module victim_policy;

enum VictimPolicy
{
    roundRobin,
    random,
    stickySuccess
}

const(char)[] victimPolicyName(
    VictimPolicy policy)
    @safe @nogc nothrow
{
    final switch (policy)
    {
        case VictimPolicy.roundRobin:
            return "round-robin";

        case VictimPolicy.random:
            return "random";

        case VictimPolicy.stickySuccess:
            return "sticky-success";
    }
}

struct VictimSelector
{
    enum uint StickyAttempts = 3;

    private size_t _workerIndex;
    private size_t _workerCount;
    private VictimPolicy _policy;

    private size_t _nextRoundRobin;

    private ulong _randomState;

    private size_t _lastSuccessful;
    private uint _stickyRemaining;
    private bool _hasLastSuccessful;

    private size_t _lastChosen;
    private bool _hasLastChosen;

    ulong victimSwitches;

    this(
        size_t workerIndex,
        size_t workerCount,
        VictimPolicy policy)
        @safe @nogc nothrow
    {
        _workerIndex =
            workerIndex;

        _workerCount =
            workerCount;

        _policy =
            policy;

        _nextRoundRobin =
            workerCount > 1
            ? (workerIndex + 1) %
                workerCount
            : workerIndex;

        /*
         * Distinct deterministic non-zero stream per worker.
         * The mixer is intentionally small: this is victim ordering,
         * not statistical simulation or cryptography.
         */
        _randomState =
            0x9e37_79b9_7f4a_7c15UL ^
            ((cast(ulong) workerIndex + 1) *
                0xbf58_476d_1ce4_e5b9UL);

        if (_randomState == 0)
            _randomState = 1;
    }

    size_t choose()
        @safe @nogc nothrow
    {
        if (_workerCount <= 1)
            return _workerIndex;

        size_t victim;

        final switch (_policy)
        {
            case VictimPolicy.roundRobin:
                victim =
                    nextRoundRobin();
                break;

            case VictimPolicy.random:
                victim =
                    nextRandom();
                break;

            case VictimPolicy.stickySuccess:
                if (
                    _hasLastSuccessful &&
                    _stickyRemaining != 0)
                {
                    victim =
                        _lastSuccessful;
                }
                else
                {
                    victim =
                        nextRandom();
                }
                break;
        }

        if (
            _hasLastChosen &&
            victim != _lastChosen)
        {
            ++victimSwitches;
        }

        _lastChosen =
            victim;

        _hasLastChosen =
            true;

        return victim;
    }

    void record(
        size_t victim,
        bool success)
        @safe @nogc nothrow
    {
        if (
            _policy !=
            VictimPolicy.stickySuccess)
        {
            return;
        }

        if (success)
        {
            _lastSuccessful =
                victim;

            _hasLastSuccessful =
                true;

            _stickyRemaining =
                StickyAttempts;

            return;
        }

        if (
            _hasLastSuccessful &&
            victim ==
                _lastSuccessful &&
            _stickyRemaining != 0)
        {
            --_stickyRemaining;

            if (
                _stickyRemaining == 0)
            {
                _hasLastSuccessful =
                    false;
            }
        }
    }

    private size_t nextRoundRobin()
        @safe @nogc nothrow
    {
        for (;;)
        {
            const victim =
                _nextRoundRobin;

            _nextRoundRobin =
                (_nextRoundRobin + 1) %
                _workerCount;

            if (
                victim !=
                _workerIndex)
            {
                return victim;
            }
        }
    }

    private size_t nextRandom()
        @safe @nogc nothrow
    {
        ulong x =
            _randomState;

        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;

        _randomState =
            x;

        const mixed =
            x *
            0x2545_f491_4f6c_dd1dUL;

        const offset =
            cast(size_t)(
                mixed %
                (_workerCount - 1)) +
            1;

        return
            (_workerIndex + offset) %
            _workerCount;
    }
}

unittest
{
    foreach (
        policy;
        [
            VictimPolicy.roundRobin,
            VictimPolicy.random,
            VictimPolicy.stickySuccess
        ])
    {
        VictimSelector selector =
            VictimSelector(
                1,
                4,
                policy);

        foreach (_; 0 .. 64)
        {
            const victim =
                selector.choose();

            assert(victim != 1);
            assert(victim < 4);

            selector.record(
                victim,
                false);
        }
    }

    VictimSelector sticky =
        VictimSelector(
            0,
            4,
            VictimPolicy.stickySuccess);

    const first =
        sticky.choose();

    sticky.record(
        first,
        true);

    foreach (_; 0 .. VictimSelector.StickyAttempts)
    {
        assert(
            sticky.choose() ==
            first);

        sticky.record(
            first,
            false);
    }
}
