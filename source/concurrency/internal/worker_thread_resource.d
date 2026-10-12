/**
 * R0.5 research-only Linux worker CPU/scheduling snapshot.
 *
 * Sampled exactly twice per worker: before and after workerLoop.
 * Never sampled during inbox enqueue, deque access or task dispatch.
 * The per-worker slot is written by its worker and may be read only
 * after all workers have joined; no extra synchronization is added.
 *
 * This module does not provide public consumer API.
 */
module concurrency.internal.worker_thread_resource;

version (R05WorkerThreadResources)
{
    version (linux)
    {
        import core.sys.posix.sys.resource :
            getrusage,
            rusage;

        package(concurrency) struct WorkerThreadResource
        {
            ulong cpuUserUs;
            ulong cpuSystemUs;
            ulong voluntarySwitches;
            ulong involuntarySwitches;
            ulong minorFaults;
            ulong majorFaults;
            bool sampled;
        }

        package(concurrency) WorkerThreadResource sampleWorkerThreadResource()
        {
            // Linux RUSAGE_THREAD GNU extension (also used in
            // benchmarks/task_pipeline/thread_resource.d).
            enum int linuxRusageThread = 1;
            rusage info;
            if (getrusage(linuxRusageThread, &info) != 0)
                throw new Exception("worker getrusage(RUSAGE_THREAD) failed");

            WorkerThreadResource result;
            result.cpuUserUs =
                cast(ulong) info.ru_utime.tv_sec * 1_000_000UL
                + cast(ulong) info.ru_utime.tv_usec;
            result.cpuSystemUs =
                cast(ulong) info.ru_stime.tv_sec * 1_000_000UL
                + cast(ulong) info.ru_stime.tv_usec;
            result.voluntarySwitches = cast(ulong) info.ru_nvcsw;
            result.involuntarySwitches = cast(ulong) info.ru_nivcsw;
            result.minorFaults = cast(ulong) info.ru_minflt;
            result.majorFaults = cast(ulong) info.ru_majflt;
            result.sampled = true;
            return result;
        }

        package(concurrency) WorkerThreadResource workerResourceDifference(
            WorkerThreadResource after,
            WorkerThreadResource before)
        {
            WorkerThreadResource result;
            result.cpuUserUs = after.cpuUserUs - before.cpuUserUs;
            result.cpuSystemUs = after.cpuSystemUs - before.cpuSystemUs;
            result.voluntarySwitches =
                after.voluntarySwitches - before.voluntarySwitches;
            result.involuntarySwitches =
                after.involuntarySwitches - before.involuntarySwitches;
            result.minorFaults = after.minorFaults - before.minorFaults;
            result.majorFaults = after.majorFaults - before.majorFaults;
            result.sampled = after.sampled && before.sampled;
            return result;
        }
    }
    else
    {
        static assert(0, "R05WorkerThreadResources requires Linux");
    }
}
