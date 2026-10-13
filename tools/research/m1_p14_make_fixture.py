#!/usr/bin/env python3
"""Generate strictly matched P14 control/instrumented P13 workloads.

P13 source and algorithm remain untouched. This generator requires exact
reviewed Git blobs, then changes only the import target and adds event
snapshot fields in the research binary. Control and traced binaries both
compile the SAME generated workload source from the same input file.
"""
import argparse
import hashlib
from pathlib import Path

P13_KERNEL_BLOB = "3852e8788757b62c5000ad55565359d6a20a78c1"
P13_MAIN_BLOB = "723de6bf76ac838b10de4b3f1cb901315a5ced38"

def read_checked(path, expected):
    data = path.read_bytes()
    actual = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    if actual != expected:
        raise RuntimeError(f"P14 re-audit needed for {path}: {actual} != {expected}")
    return data.decode()

def once(text, old, new):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"P14 expected exactly one source anchor ({count}): {old[:80]}")
    return text.replace(old, new, 1)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("driver", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    code = read_checked(args.kernel, P13_KERNEL_BLOB)
    driver = read_checked(args.driver, P13_MAIN_BLOB)
    code = once(code,
        "module concurrency.research.m1_scaling_kernel;",
        "module concurrency.research.m1_p14_kernel;")
    code = once(code,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P14Instrumented)
{
    import concurrency.research.m1_p14_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}""")
    code = once(code, "struct ScalingSample\n{",
        """struct P14Events
{
    ulong fullSubmissions;
    ulong acceptedSubmissions;
    ulong submitSignals;
    ulong localSignals;
    ulong completeCalls;
    ulong finalSignals;
    ulong closeSignals;
    ulong parkWaits;
    ulong localHits;
    ulong localMisses;
    ulong inboxBatchAttempts;
    ulong inboxBatchClaims;
    ulong inboxBatchTasks;
    ulong localPushes;
    ulong localPushFailures;
    ulong stealAttempts;
    ulong stealSuccesses;
    ulong parkAttempts;
    ulong executed;
    size_t workerCount;
    ulong[16] workerExecuted;
}
struct ScalingSample
{""")
    code = once(code,
        "    ulong checksum;\n    long prepareNs;",
        "    ulong checksum;\n    P14Events events;\n    long prepareNs;")
    code = once(code,
        """    if (pool.acceptedCount() != all || pool.completedCount() != all)
        throw new Exception("P13 real pool lost accepted work");
    sample.parkCount = pool.parkCount();""",
        """    if (pool.acceptedCount() != all || pool.completedCount() != all)
        throw new Exception("P13 real pool lost accepted work");
    sample.parkCount = pool.parkCount();

    version (P14Instrumented)
    {
        // The snapshot is valid only after every native worker joined.
        // A worker writes only its own cache-aligned counters. The inbox
        // owns its counters under its existing mutex.
        auto trace = pool.p14Snapshot();
        if (trace.acceptedSubmissions != all ||
            trace.submitSignals != all ||
            trace.completeCalls != all ||
            trace.executed != all ||
            trace.inboxBatchTasks != all ||
            trace.fullSubmissions != sample.retries ||
            trace.parkWaits != sample.parkCount ||
            trace.inboxBatchTasks !=
                trace.localPushes + trace.localPushFailures +
                trace.inboxBatchClaims ||
            trace.executed !=
                trace.localHits + trace.stealSuccesses +
                trace.inboxBatchClaims + trace.localPushFailures ||
            trace.localPushes !=
                trace.localHits + trace.stealSuccesses ||
            trace.stealSuccesses > trace.stealAttempts ||
            trace.workerCount != workers)
            throw new Exception("P14 instrumentation event conservation failure");

        ulong workerSum;
        foreach (i; 0 .. trace.workerCount)
            workerSum += trace.workerExecuted[i];
        if (workerSum != all)
            throw new Exception("P14 per-worker execution distribution mismatch");

        sample.events = P14Events(
            trace.fullSubmissions, trace.acceptedSubmissions,
            trace.submitSignals, trace.localSignals,
            trace.completeCalls, trace.finalSignals,
            trace.closeSignals, trace.parkWaits,
            trace.localHits, trace.localMisses,
            trace.inboxBatchAttempts, trace.inboxBatchClaims,
            trace.inboxBatchTasks, trace.localPushes,
            trace.localPushFailures, trace.stealAttempts,
            trace.stealSuccesses, trace.parkAttempts, trace.executed);
        sample.events.workerCount = trace.workerCount;
        sample.events.workerExecuted = trace.workerExecuted;
    }""")

    driver = once(driver,
        "module concurrency.research.p13_consumer;",
        "module concurrency.research.p14_consumer;")
    driver = once(driver,
        "import concurrency.research.m1_scaling_kernel :",
        "import concurrency.research.m1_p14_kernel :")
    driver = once(driver,
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum);""",
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum,
        ",", sample.events.fullSubmissions,
        ",", sample.events.acceptedSubmissions,
        ",", sample.events.submitSignals,
        ",", sample.events.localSignals,
        ",", sample.events.completeCalls,
        ",", sample.events.finalSignals,
        ",", sample.events.closeSignals,
        ",", sample.events.parkWaits,
        ",", sample.events.localHits,
        ",", sample.events.localMisses,
        ",", sample.events.inboxBatchAttempts,
        ",", sample.events.inboxBatchClaims,
        ",", sample.events.inboxBatchTasks,
        ",", sample.events.localPushes,
        ",", sample.events.localPushFailures,
        ",", sample.events.stealAttempts,
        ",", sample.events.stealSuccesses,
        ",", sample.events.parkAttempts,
        ",", sample.events.executed,
        ",", sample.events.workerCount,
        ",", sample.events.workerExecuted[0],
        ",", sample.events.workerExecuted[1],
        ",", sample.events.workerExecuted[2],
        ",", sample.events.workerExecuted[3],
        ",", sample.events.workerExecuted[4],
        ",", sample.events.workerExecuted[5],
        ",", sample.events.workerExecuted[6],
        ",", sample.events.workerExecuted[7],
        ",", sample.events.workerExecuted[8],
        ",", sample.events.workerExecuted[9],
        ",", sample.events.workerExecuted[10],
        ",", sample.events.workerExecuted[11],
        ",", sample.events.workerExecuted[12],
        ",", sample.events.workerExecuted[13],
        ",", sample.events.workerExecuted[14],
        ",", sample.events.workerExecuted[15]);""")
    driver = once(driver,
        """        "retries,park_count,checksum");""",
        """        "retries,park_count,checksum,",
        "full_submits,accepted_submits,submit_signals,local_signals,",
        "complete_calls,final_signals,close_signals,park_waits,",
        "local_hits,local_misses,batch_attempts,batch_claims,",
        "batch_tasks,local_pushes,local_push_failures,steal_attempts,",
        "steal_successes,park_attempts,executed,worker_count,",
        "worker0_executed,worker1_executed,worker2_executed,",
        "worker3_executed,worker4_executed,worker5_executed,",
        "worker6_executed,worker7_executed,worker8_executed,",
        "worker9_executed,worker10_executed,worker11_executed,",
        "worker12_executed,worker13_executed,worker14_executed,",
        "worker15_executed");""")

    # Make the two executable modes clearly distinguishable without
    # affecting task work or the shuffled scenario sequence.
    driver = once(driver,
        '    stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",',
        '    stderr.writeln("P14 identical-control/instrumented research only; ",')

    for relative, body in (
        ("concurrency/research/m1_p14_kernel.d", code),
        ("consumer/main.d", driver),
    ):
        out = args.destination / relative
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            "// AUTO-GENERATED P14 FROM EXACT P13 SOURCE — DO NOT EDIT.\n"
            + body, encoding="utf-8")
        print(f"P14 generated {out}")

if __name__ == "__main__":
    main()
