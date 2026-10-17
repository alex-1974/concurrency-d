#!/usr/bin/env python3
"""P17 same exact P13 TaskRef kernel, four compile modes, no work changes."""
import argparse
import hashlib
from pathlib import Path

KERNEL = "3852e8788757b62c5000ad55565359d6a20a78c1"
DRIVER = "723de6bf76ac838b10de4b3f1cb901315a5ced38"

def checked(path, expected):
    raw = path.read_bytes()
    sha = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if sha != expected:
        raise RuntimeError(f"P17 P13 source changed: {path}, got {sha}")
    return raw.decode()

def once(s, before, after):
    n = s.count(before)
    if n != 1:
        raise RuntimeError(f"P17 exact fixture anchor mismatch ({n}) {before[:90]!r}")
    return s.replace(before, after, 1)

def generate(kernel, driver, root):
    s = checked(kernel, KERNEL)
    t = checked(driver, DRIVER)
    s = once(s, "module concurrency.research.m1_scaling_kernel;",
             "module concurrency.research.m1_p17_kernel;")
    s = once(s,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P17TraceControl)
{
    import concurrency.research.m1_p17_control_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else version (P17TraceAtomic)
{
    import concurrency.research.m1_p17_atomic_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else version (P17Atomic)
{
    import concurrency.research.m1_p16_2_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}""")
    s = once(s, "    ulong checksum;\n    long prepareNs;",
        """    ulong checksum;
    ulong p17StealAttempts;
    ulong p17StealSuccesses;
    ulong p17ParkAttempts;
    ulong p17ParkWaits;
    ulong p17ParkNoOutstanding;
    ulong p17ParkWithOutstanding;
    ulong p17BatchClaims;
    ulong p17BatchTasks;
    ulong p17LocalHits;
    ulong p17LocalMisses;
    ulong p17MinWorkerTasks;
    ulong p17MaxWorkerTasks;
    long prepareNs;""")
    snippet = """        auto ev = pool.p17Snapshot();
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
            throw new Exception("P17 event conservation failed");
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
            throw new Exception("P17 per-worker task accounting failed");
        sample.p17StealAttempts = ev.stealAttempts;
        sample.p17StealSuccesses = ev.stealSuccesses;
        sample.p17ParkAttempts = ev.parkAttempts;
        sample.p17ParkWaits = ev.parkWaits;
        sample.p17ParkNoOutstanding = ev.parkWaitsNoOutstanding;
        sample.p17ParkWithOutstanding = ev.parkWaitsWithOutstanding;
        sample.p17BatchClaims = ev.batchClaims;
        sample.p17BatchTasks = ev.batchTasks;
        sample.p17LocalHits = ev.localHits;
        sample.p17LocalMisses = ev.localMisses;
        sample.p17MinWorkerTasks = low;
        sample.p17MaxWorkerTasks = high;"""
    s = once(s,
        """    sample.parkCount = pool.parkCount();

    ulong expected;""",
        """    sample.parkCount = pool.parkCount();
    version (P17TraceControl)
    {
""" + snippet + """
    }
    version (P17TraceAtomic)
    {
""" + snippet + """
    }

    ulong expected;""")
    t = once(t,"module concurrency.research.p13_consumer;",
             "module concurrency.research.p17_consumer;")
    t = once(t, "import concurrency.research.m1_scaling_kernel :",
             "import concurrency.research.m1_p17_kernel :")
    t = once(t,
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum);""",
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum,
        ",", sample.p17StealAttempts, ",", sample.p17StealSuccesses,
        ",", sample.p17ParkAttempts, ",", sample.p17ParkWaits,
        ",", sample.p17ParkNoOutstanding, ",",
        sample.p17ParkWithOutstanding, ",", sample.p17BatchClaims,
        ",", sample.p17BatchTasks, ",", sample.p17LocalHits,
        ",", sample.p17LocalMisses, ",", sample.p17MinWorkerTasks,
        ",", sample.p17MaxWorkerTasks);""")
    t = once(t,
        """        "retries,park_count,checksum");""",
        """        "retries,park_count,checksum,steal_attempts,steal_successes,",
        "park_attempts,park_waits,park_no_outstanding,",
        "park_with_outstanding,batch_claims,batch_tasks,",
        "local_hits,local_misses,min_worker_tasks,max_worker_tasks");""")
    t = once(t,
        'stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",',
        'stderr.writeln("P17 scheduler-event study is DIAGNOSTIC ONLY; ",')
    for p, data in [
        ("concurrency/research/m1_p17_kernel.d",s),
        ("consumer/main.d",t)
    ]:
        target = root / p
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("// EXACT P13 GENERATED P17 WORKLOAD.\n" + data)
        print("P17 generated",target)

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("kernel",type=Path)
    a.add_argument("driver",type=Path)
    a.add_argument("destination",type=Path)
    v=a.parse_args()
    generate(v.kernel,v.driver,v.destination)
