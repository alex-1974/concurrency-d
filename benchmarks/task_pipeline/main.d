/**
 * R0.5 owned-task end-to-end performance qualification.
 *
 * This executable measures the same accepted-task, result-observation,
 * exception-free and draining-shutdown contract with fresh-GC and typed
 * recycled node storage. Shared CI results are diagnostics, not speed gates.
 */
module concurrency.benchmarks.task_pipeline;

import concurrency.internal.owned_task :
    OwnedRecordPolicy,
    OwnedTaskExecutor;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad;

import core.memory :
    GC;

import core.time :
    MonoTime,
    ticksToNSecs;

import std.conv :
    to;

import std.stdio :
    writefln;

private struct ScalarWork
{
    shared(ulong)* counter;
    int value;

    int opCall()
    {
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
        return value + 1;
    }
}

private struct WideWork
{
    shared(ulong)* counter;
    string label;
    ubyte[256] payload;
    int value;

    int opCall()
    {
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
        return value + 1 + payload[0] + cast(int) label.length;
    }
}

private struct VoidWork
{
    shared(ulong)* counter;
    int value;

    void opCall()
    {
        // Keep comparable observable work across all storage policies.
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
    }
}

private string policyName(OwnedRecordPolicy policy)
{
    return policy == OwnedRecordPolicy.freshGc ? "gc" : "recycle";
}

private void runCase(F)(
    string scenario,
    size_t workers,
    size_t tasks,
    size_t budget,
    OwnedRecordPolicy policy,
    size_t round)
{
    // A single producer; workers perform the task code, increment one
    // shared atomic, record the result and complete the queue obligation.
    // All modes use identical executor admission and TaskHandle contracts.
    shared ulong counter;
    size_t checkedHandles;

    GC.collect();
    const beforeBytes = GC.allocatedInCurrentThread();
    const beforeUsed = GC.stats().usedSize;
    const start = MonoTime.currTime;

    auto executor = new OwnedTaskExecutor(
        workers, 64, budget, policy);

    foreach (i; 0 .. tasks)
    {
        F work;
        work.counter = &counter;
        work.value = cast(int) i;

        static if (is(F == WideWork))
        {
            work.label = "reusable-owned-node";
            work.payload[0] = 7;
        }

        auto handle = executor.submit(work);

        // Observe some handles before joining, and let the others go.
        // The scheduler must still complete *all* accepted work.
        if (i % 17 == 0)
        {
            static if (is(F == VoidWork))
            {
                handle.get();
            }
            else static if (is(F == WideWork))
            {
                assert(handle.get() ==
                    cast(int) i + 1 + 7 + work.label.length);
            }
            else
            {
                assert(handle.get() == cast(int) i + 1);
            }

            ++checkedHandles;
        }
    }

    executor.closeAndJoin();
    const elapsed = ticksToNSecs(
        MonoTime.currTime.ticks - start.ticks);

    const afterBytes = GC.allocatedInCurrentThread();
    const afterUsed = GC.stats().usedSize;

    assert(executor.acceptedCount() == tasks);
    assert(executor.completedCount() == tasks);
    assert(atomicLoad!(MemoryOrder.acq)(counter) == tasks);
    assert(executor.retainedCount() == 0);
    assert(executor.spareCount() == 0);

    const double seconds = cast(double) elapsed / 1_000_000_000.0;
    const double throughput = cast(double) tasks / seconds;
    const long usedChange =
        cast(long) afterUsed - cast(long) beforeUsed;

    writefln(
        "pipeline,%s,%s,%s,%s,%s,%s,%.3f,%.1f,%s,%s,%s,%s,%s",
        scenario,
        policyName(policy),
        workers,
        budget,
        tasks,
        round,
        cast(double) elapsed / 1_000_000.0,
        throughput,
        executor.freshNodeCount(),
        executor.reusedNodeCount(),
        afterBytes - beforeBytes,
        usedChange,
        checkedHandles);
}

void main(string[] args)
{
    size_t workers = 2;
    size_t tasks = 1024;
    size_t rounds = 1;
    string scenario = "scalar";
    string policyFilter = "both";
    size_t budgetFilter;

    if (args.length > 1)
        workers = to!size_t(args[1]);
    if (args.length > 2)
        tasks = to!size_t(args[2]);
    if (args.length > 3)
        rounds = to!size_t(args[3]);
    if (args.length > 4)
        scenario = args[4];
    if (args.length > 5)
        policyFilter = args[5];
    if (args.length > 6)
        budgetFilter = to!size_t(args[6]);

    if (workers == 0 || workers > 64 ||
        tasks == 0 || tasks > 2_000_000 ||
        rounds == 0 || rounds > 20)
        throw new Exception("invalid worker/task/round count");

    if (scenario != "scalar" && scenario != "wide" &&
        scenario != "void" && scenario != "all")
        throw new Exception("scenario must be scalar/wide/void/all");

    if (policyFilter != "gc" && policyFilter != "recycle" &&
        policyFilter != "both")
        throw new Exception("policy must be gc/recycle/both");

    if (budgetFilter != 0 && budgetFilter != 8 &&
        budgetFilter != 64 && budgetFilter != 512 &&
        budgetFilter != 4096)
        throw new Exception("budget must be 0/8/64/512/4096");

    // One process, paired policies and alternating order across rounds.
    // Budget 8 intentionally exercises constrained reclaim/pressure;
    // larger budgets expose the effect of amortization.
    enum size_t[4] budgets = [8, 64, 512, 4096];

    writefln("R0.5 end-to-end: workers=%s tasks=%s rounds=%s scenario=%s",
        workers, tasks, rounds, scenario);
    writefln(
        "metric,scenario,policy,workers,budget,tasks,round,"
        ~ "elapsed_ms,throughput_per_s,fresh_nodes,reused_nodes,"
        ~ "producer_gc_bytes,gc_used_delta,observed_handles");

    foreach (round; 0 .. rounds)
    {
        foreach (budget; budgets[])
        {
            if (budgetFilter != 0 && budget != budgetFilter)
                continue;

            foreach (variant; 0 .. 2)
            {
                const policy = ((variant + round) % 2) == 0
                    ? OwnedRecordPolicy.freshGc
                    : OwnedRecordPolicy.recycleTyped;

                if (policyFilter != "both" &&
                    policyName(policy) != policyFilter)
                    continue;

                if (scenario == "scalar" || scenario == "all")
                    runCase!ScalarWork("scalar", workers, tasks,
                        budget, policy, round);

                if (scenario == "wide" || scenario == "all")
                    runCase!WideWork("wide", workers, tasks,
                        budget, policy, round);

                if (scenario == "void" || scenario == "all")
                    runCase!VoidWork("void", workers, tasks,
                        budget, policy, round);
            }
        }
    }
}
