/**
 * R0.5 Linux-only resource snapshot, sampled at producer-thread boundaries.
 *
 * getrusage(RUSAGE_THREAD) counts this calling thread only, not the whole
 * process. The constant is 1 on Linux; D's standard POSIX interface may
 * omit the GNU-extension symbol on some supported compiler versions.
 *
 * Sampling occurs outside the task admission path. This module is a
 * research executable helper, not a library API.
 */
module concurrency.benchmarks.thread_resource;

version (linux)
{
    import core.sys.posix.sys.resource :
        getrusage,
        rusage;

    package struct ThreadResourceSnapshot
    {
        ulong cpuUserUs;
        ulong cpuSystemUs;
        ulong voluntarySwitches;
        ulong involuntarySwitches;
        ulong minorFaults;
        ulong majorFaults;
    }

    package ThreadResourceSnapshot sampleThreadResources()
    {
        enum int linuxRusageThread = 1;

        rusage info;
        if (getrusage(linuxRusageThread, &info) != 0)
            throw new Exception("getrusage(RUSAGE_THREAD) failed");

        ThreadResourceSnapshot result;
        result.cpuUserUs = cast(ulong) info.ru_utime.tv_sec * 1_000_000UL
            + cast(ulong) info.ru_utime.tv_usec;
        result.cpuSystemUs = cast(ulong) info.ru_stime.tv_sec * 1_000_000UL
            + cast(ulong) info.ru_stime.tv_usec;
        result.voluntarySwitches = cast(ulong) info.ru_nvcsw;
        result.involuntarySwitches = cast(ulong) info.ru_nivcsw;
        result.minorFaults = cast(ulong) info.ru_minflt;
        result.majorFaults = cast(ulong) info.ru_majflt;
        return result;
    }

    package ThreadResourceSnapshot difference(
        ThreadResourceSnapshot after,
        ThreadResourceSnapshot before)
    {
        ThreadResourceSnapshot result;
        result.cpuUserUs = after.cpuUserUs - before.cpuUserUs;
        result.cpuSystemUs = after.cpuSystemUs - before.cpuSystemUs;
        result.voluntarySwitches =
            after.voluntarySwitches - before.voluntarySwitches;
        result.involuntarySwitches =
            after.involuntarySwitches - before.involuntarySwitches;
        result.minorFaults = after.minorFaults - before.minorFaults;
        result.majorFaults = after.majorFaults - before.majorFaults;
        return result;
    }
}
else
{
    static assert(0, "R0.5 thread-resource research requires Linux");
}
