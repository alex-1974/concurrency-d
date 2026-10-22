#!/usr/bin/env python3
"""P18 exact P13 TaskRef kernel, event-only M0/grace overlays."""
import argparse
import hashlib
from pathlib import Path

KERNEL = "3852e8788757b62c5000ad55565359d6a20a78c1"
DRIVER = "723de6bf76ac838b10de4b3f1cb901315a5ced38"

def checked(path, expected):
    raw = path.read_bytes()
    sha = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if sha != expected:
        raise RuntimeError(f"P18 P13 source changed: {path}, got {sha}")
    return raw.decode()

def once(s, before, after):
    n = s.count(before)
    if n != 1:
        raise RuntimeError(f"P18 exact fixture anchor mismatch ({n}) {before[:90]!r}")
    return s.replace(before, after, 1)

def generate(kernel, driver, root):
    s = checked(kernel, KERNEL)
    t = checked(driver, DRIVER)
    s = once(s, "module concurrency.research.m1_scaling_kernel;",
             "module concurrency.research.m1_p18_trace_kernel;")
    s = once(s,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P18TraceControl)
{
    import concurrency.research.m1_p18_trace_control_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else version (P18TraceGrace)
{
    import concurrency.research.m1_p18_trace_grace_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}""")
    s = once(s, "    ulong checksum;\n    long prepareNs;",
        """    ulong checksum;
    ulong p18GraceSearches;
    ulong p18GraceRecoveredLocal;
    ulong p18GraceRecoveredInbox;
    ulong p18GraceRecoveredSteal;
    ulong p18GraceFallbacks;
    ulong p18GraceDrainExits;
    ulong p18StealAttempts;
    ulong p18StealSuccesses;
    ulong p18ParkAttempts;
    ulong p18ParkWaits;
    ulong p18ParkNoOutstanding;
    ulong p18ParkWithOutstanding;
    ulong p18BatchClaims;
    ulong p18BatchTasks;
    ulong p18LocalHits;
    ulong p18LocalMisses;
    ulong p18MinWorkerTasks;
    ulong p18MaxWorkerTasks;
    long prepareNs;""")
    snippet = """        auto ev = pool.p18TraceSnapshot();
        if (ev.workerCount != workers ||
            ev.executed != all ||
            ev.batchTasks != all ||
            ev.parkWaits != sample.parkCount ||
            ev.parkWaitsNoOutstanding + ev.parkWaitsWithOutstanding
                != ev.parkWaits ||
            ev.stealSuccesses > ev.stealAttempts ||
            ev.batchClaims > ev.batchTasks ||
            ev.localHits + ev.stealSuccesses > all ||
            ev.parkAttempts < ev.parkWaits)
            throw new Exception("P18 event conservation failed");
        ulong accounted;
        ulong low = ulong.max;
        ulong high;
        foreach (i; 0 .. workers)
        {
            const n = ev.workerExecuted[i];
            accounted += n;
            if (n < low) low = n;
            if (n > high) high = n;
        }
        if (accounted != all)
            throw new Exception("P18 per-worker task accounting failed");
        if (ev.graceSearches !=
            ev.graceRecoveredLocal + ev.graceRecoveredInbox +
            ev.graceRecoveredSteal + ev.graceFallbacks +
            ev.graceDrainExits)
            throw new Exception("P18 grace attempt conservation failed");
        version (P18TraceControl)
        {
            if (ev.graceSearches != 0 || ev.graceFallbacks != 0)
                throw new Exception("Original M0 trace entered a P18 retry");
        }
        sample.p18GraceSearches = ev.graceSearches;
        sample.p18GraceRecoveredLocal = ev.graceRecoveredLocal;
        sample.p18GraceRecoveredInbox = ev.graceRecoveredInbox;
        sample.p18GraceRecoveredSteal = ev.graceRecoveredSteal;
        sample.p18GraceFallbacks = ev.graceFallbacks;
        sample.p18GraceDrainExits = ev.graceDrainExits;
        sample.p18StealAttempts = ev.stealAttempts;
        sample.p18StealSuccesses = ev.stealSuccesses;
        sample.p18ParkAttempts = ev.parkAttempts;
        sample.p18ParkWaits = ev.parkWaits;
        sample.p18ParkNoOutstanding = ev.parkWaitsNoOutstanding;
        sample.p18ParkWithOutstanding = ev.parkWaitsWithOutstanding;
        sample.p18BatchClaims = ev.batchClaims;
        sample.p18BatchTasks = ev.batchTasks;
        sample.p18LocalHits = ev.localHits;
        sample.p18LocalMisses = ev.localMisses;
        sample.p18MinWorkerTasks = low;
        sample.p18MaxWorkerTasks = high;"""
    s = once(s,
        """    sample.parkCount = pool.parkCount();

    ulong expected;""",
        """    sample.parkCount = pool.parkCount();
    version (P18TraceControl)
    {
""" + snippet + """
    }
    version (P18TraceGrace)
    {
""" + snippet + """
    }

    ulong expected;""")
    t = once(t,"module concurrency.research.p13_consumer;",
             "module concurrency.research.p18_trace_consumer;")
    t = once(t, "import concurrency.research.m1_scaling_kernel :",
             "import concurrency.research.m1_p18_trace_kernel :")
    # Keep P13 source immutable; only the generated TRACE driver extends
    # the same 128 / 512 / 1024 focused workload.
    t = once(t,
        'options.profile != "smoke" && options.profile != "native"',
        'options.profile != "smoke" && options.profile != "native" && options.profile != "focus512"')
    t = once(t,
        '? [0, 128] : [0, 8, 32, 128, 512];',
        '? [0, 128] : profile == "focus512" ? [128, 512, 1024] : [0, 8, 32, 128, 512];')
    t = once(t,
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum);""",
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum,
        ",", sample.p18GraceSearches, ",", sample.p18GraceRecoveredLocal,
        ",", sample.p18GraceRecoveredInbox, ",", sample.p18GraceRecoveredSteal,
        ",", sample.p18GraceFallbacks, ",", sample.p18GraceDrainExits,
        ",", sample.p18StealAttempts, ",", sample.p18StealSuccesses,
        ",", sample.p18ParkAttempts, ",", sample.p18ParkWaits,
        ",", sample.p18ParkNoOutstanding, ",",
        sample.p18ParkWithOutstanding, ",", sample.p18BatchClaims,
        ",", sample.p18BatchTasks, ",", sample.p18LocalHits,
        ",", sample.p18LocalMisses, ",", sample.p18MinWorkerTasks,
        ",", sample.p18MaxWorkerTasks);""")
    t = once(t,
        """        "retries,park_count,checksum");""",
        """        "retries,park_count,checksum,grace_searches,",
        "grace_recovered_local,grace_recovered_inbox,",
        "grace_recovered_steal,grace_fallbacks,grace_drain_exits,",
        "steal_attempts,steal_successes,",
        "park_attempts,park_waits,park_no_outstanding,",
        "park_with_outstanding,batch_claims,batch_tasks,",
        "local_hits,local_misses,min_worker_tasks,max_worker_tasks");""")
    t = once(t,
        'stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",',
        'stderr.writeln("P18 scheduler-event study is DIAGNOSTIC ONLY; ",')
    for p, data in [
        ("concurrency/research/m1_p18_trace_kernel.d",s),
        ("trace/consumer/main.d",t)
    ]:
        target = root / p
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("// EXACT P13 GENERATED P18 EVENT-ONLY WORKLOAD.\n" + data)
        print("P18 generated",target)

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("kernel",type=Path)
    a.add_argument("driver",type=Path)
    a.add_argument("destination",type=Path)
    v=a.parse_args()
    generate(v.kernel,v.driver,v.destination)
