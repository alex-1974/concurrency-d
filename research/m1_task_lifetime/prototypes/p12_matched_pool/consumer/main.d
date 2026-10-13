/++
 Reproducible P12 matched-semantics benchmark. No performance threshold;
 shared CI runner results are smoke/diagnostic ONLY.
 CSV is deliberately machine-readable for local XPS benchmark qualification.
+/
module concurrency.research.p12_main;

import concurrency.research.m1_matched_pool_benchmark :
    MaxTasks, Sample, measureHeap, measureStack;
import std.conv : to;
import std.stdio : writeln, stderr;

private struct Options
{
    size_t count = MaxTasks;
    size_t workers = 2;
    size_t ingress = 64;
    size_t warmup = 3;
    size_t rounds = 9;
}

private Options parse(string[] args)
{
    Options options;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (i + 1 == args.length)
            throw new Exception("P12 expected value after option " ~ args[i]);
        const argument = args[i];
        const value = to!size_t(args[++i]);
        switch (argument)
        {
            case "--count": options.count = value; break;
            case "--workers": options.workers = value; break;
            case "--ingress": options.ingress = value; break;
            case "--warmup": options.warmup = value; break;
            case "--rounds": options.rounds = value; break;
            default: throw new Exception("P12 unknown option " ~ argument);
        }
    }
    if (options.count < 1 || options.count > MaxTasks)
        throw new Exception("P12 count out of bounds");
    if (options.workers < 1 || options.workers > 16)
        throw new Exception("P12 workers out of bounds");
    if (options.ingress < 1 || options.ingress > 1024)
        throw new Exception("P12 ingress out of bounds");
    if (options.warmup > 20 || options.rounds < 1 || options.rounds > 100)
        throw new Exception("P12 warmup/rounds out of bounds");
    return options;
}

private void emit(string stage, size_t pair, string mode,
    Options options, Sample result)
{
    // Independent preparation and runtime stages are recorded, but their
    // values are subject to scheduler overlap and arbitrary OS load.
    writeln(stage, ",", pair, ",", mode, ",",
        options.count, ",", options.workers, ",", options.ingress, ",",
        result.storageAndPrepareNs, ",",
        result.workerStartNs, ",",
        result.submitAndJoinNs, ",",
        result.verifyNs, ",",
        result.totalNs, ",",
        result.retries, ",",
        result.checksum);
}

void main(string[] args)
{
    const opts = parse(args);
    stderr.writeln("P12 research diagnostic ONLY: do not use CI timing for a speed claim.");
    writeln("phase,pair,mode,count,workers,ingress,prepare_ns,",
        "pool_start_ns,submit_join_ns,verify_ns,total_ns,retries,checksum");

    foreach (pair; 0 .. opts.warmup + opts.rounds)
    {
        const phase = pair < opts.warmup ? "warmup" : "measure";
        // AB / BA alternate within pairs to mitigate systematic CPU drift.
        const reverse = (pair & 1) != 0;
        Sample first;
        Sample second;
        string firstLabel;
        string secondLabel;

        if (reverse)
        {
            first = measureHeap(opts.count, opts.workers, opts.ingress);
            second = measureStack(opts.count, opts.workers, opts.ingress);
            firstLabel = "heap";
            secondLabel = "stack";
        }
        else
        {
            first = measureStack(opts.count, opts.workers, opts.ingress);
            second = measureHeap(opts.count, opts.workers, opts.ingress);
            firstLabel = "stack";
            secondLabel = "heap";
        }

        // Paired parity, including checksum and accepted+returned checks
        // inside the actual M0 worker-pool execution kernel.
        if (first.count != opts.count ||
            second.count != opts.count ||
            first.checksum != second.checksum)
            throw new Exception("P12 paired semantics/checksum mismatch");
        emit(phase, pair, firstLabel, opts, first);
        emit(phase, pair, secondLabel, opts, second);
    }
}
