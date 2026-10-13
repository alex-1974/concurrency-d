/++
 P13 research-only real M0 scaling sweep. No CI performance thresholds.
 Every combination is executed once per round, using a recorded seeded
 permutation to avoid confounding one worker count with run order.

 This is a workload characterization, not a proof of fairness or an
 accepted optimization. No public @safe scheduler is exported.
+/
module concurrency.research.p13_consumer;

import concurrency.research.m1_scaling_kernel :
    MaxTasksPerWave, MaxWaves, ScalingSample, measure;
import std.conv : to;
import std.stdio : writeln, stderr;

private struct Options
{
    string profile = "smoke";
    size_t count = 256;
    size_t waves = 2;
    size_t warmup = 1;
    size_t rounds = 2;
    uint seed = 0x13C0FFEEu;
}

private struct Scenario
{
    size_t workers;
    size_t iterations;
    size_t ingress;
}

private Options parse(string[] args)
{
    Options options;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (i + 1 >= args.length)
            throw new Exception("P13 missing option value");
        const flag = args[i];
        const value = args[++i];
        switch (flag)
        {
            case "--profile": options.profile = value; break;
            case "--count": options.count = to!size_t(value); break;
            case "--waves": options.waves = to!size_t(value); break;
            case "--warmup": options.warmup = to!size_t(value); break;
            case "--rounds": options.rounds = to!size_t(value); break;
            case "--seed": options.seed = to!uint(value); break;
            default: throw new Exception("P13 unknown option " ~ flag);
        }
    }
    if (options.profile != "smoke" && options.profile != "native")
        throw new Exception("P13 unknown research profile");
    if (options.count < 1 || options.count > MaxTasksPerWave ||
        options.waves < 1 || options.waves > MaxWaves ||
        options.warmup > 8 || options.rounds < 1 ||
        options.rounds > 24 || options.seed == 0u)
        throw new Exception("P13 invalid experiment parameters");
    return options;
}

private uint nextRandom(ref uint state)
{
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

private Scenario[] experimentCases(string profile)
{
    Scenario[] scenarios;
    const size_t[] workers = [1, 2, 4];
    const size_t[] kernels = profile == "smoke"
        ? [0, 128] : [0, 8, 32, 128, 512];
    const size_t[] ingresses = profile == "smoke"
        ? [64] : [8, 64, 256];

    foreach (iterations; kernels)
        foreach (ingress; ingresses)
            foreach (worker; workers)
                scenarios ~= Scenario(worker, iterations, ingress);
    return scenarios;
}

private void emit(string phase, size_t round, size_t order,
    uint seed, ScalingSample sample)
{
    writeln(phase, ",", round, ",", order, ",", seed, ",",
        sample.workers, ",", sample.tasksPerWave, ",",
        sample.waves, ",", sample.iterations, ",", sample.ingress, ",",
        sample.prepareNs, ",", sample.poolStartNs, ",",
        sample.wavesNs, ",", sample.joinNs, ",",
        sample.verifyNs, ",", sample.totalNs, ",",
        sample.retries, ",", sample.parkCount, ",", sample.checksum);
}

void main(string[] args)
{
    const options = parse(args);
    auto casesToRun = experimentCases(options.profile);
    uint generator = options.seed;

    stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",
        "the scheduler remains @system and native errors unqualified.");
    writeln("phase,round,order,seed,workers,count,waves,iterations,ingress,",
        "prepare_ns,pool_start_ns,waves_ns,join_ns,verify_ns,total_ns,",
        "retries,park_count,checksum");

    foreach (round; 0 .. options.warmup + options.rounds)
    {
        const phase = round < options.warmup ? "warmup" : "measure";
        auto schedule = casesToRun.dup;

        // Deterministic Fisher–Yates shuffle. The seed is in EVERY CSV row
        // and the round/order make drift analysis independently possible.
        foreach_reverse (i; 1 .. schedule.length)
        {
            const j = cast(size_t)(nextRandom(generator) % (i + 1));
            const temp = schedule[i];
            schedule[i] = schedule[j];
            schedule[j] = temp;
        }

        foreach (position, item; schedule)
        {
            const sample = measure(item.workers, options.count,
                options.waves, item.iterations, item.ingress);
            emit(phase, round, position, options.seed, sample);
        }
    }
}
