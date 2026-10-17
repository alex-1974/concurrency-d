#!/usr/bin/env python3
"""Generate identical P13 worker-wave workload for P15 M0 control/timed pool.

Preserve all output/result/lifetime behavior and random scenario order.
The only variable is importing original M0 versus P15Timed research copy.
Source hashes make any accidental P13 work change a review failure.
"""
from pathlib import Path
import argparse
import hashlib

KERNEL_BLOB = "3852e8788757b62c5000ad55565359d6a20a78c1"
DRIVER_BLOB = "723de6bf76ac838b10de4b3f1cb901315a5ced38"

def exact(path, expected):
    raw = path.read_bytes()
    digest = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if digest != expected:
        raise RuntimeError(f"P15 P13 source drift: {path} {digest} != {expected}")
    return raw.decode("utf8")

def once(s, a, b):
    n = s.count(a)
    if n != 1:
        raise RuntimeError(f"P15 anchor missing/duplicated ({n}): {a[:90]!r}")
    return s.replace(a, b, 1)

def generate(kernel, driver, dest):
    s = exact(kernel, KERNEL_BLOB)
    t = exact(driver, DRIVER_BLOB)

    s = once(s, "module concurrency.research.m1_scaling_kernel;",
             "module concurrency.research.m1_p15_kernel;")
    s = once(s,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P15Timed)
{
    import concurrency.research.m1_p15_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}""")
    s = once(s,
        """    ulong checksum;
    long prepareNs;""",
        """    ulong checksum;
    // Ordered sites: submit, takeBatch, completeOne,
    // wakeGeneration, announceLocalWork.
    ulong[5] p15Calls;
    ulong[5] p15WaitNs;
    ulong[5] p15HoldNs;
    ulong[5] p15MaxWaitNs;
    ulong[5] p15MaxHoldNs;
    long prepareNs;""")
    s = once(s,
        """    sample.parkCount = pool.parkCount();

    ulong expected;""",
        """    sample.parkCount = pool.parkCount();
    version (P15Timed)
    {
        // Read only AFTER successful native join; no live worker writes.
        auto t = pool.p15Snapshot();
        foreach (index; 0 .. 5)
        {
            sample.p15Calls[index] = t.entries[index].calls;
            sample.p15WaitNs[index] = t.entries[index].waitNs;
            sample.p15HoldNs[index] = t.entries[index].holdNs;
            sample.p15MaxWaitNs[index] = t.entries[index].maxWaitNs;
            sample.p15MaxHoldNs[index] = t.entries[index].maxHoldNs;
        }
        // The original accepted/completed obligation is unchanged.
        const expectedAttempts = sample.retries + all;
        if (sample.p15Calls[0] != expectedAttempts ||
            sample.p15Calls[2] != all ||
            sample.p15Calls[1] == 0)
            throw new Exception("P15 timed lock call conservation failed");
    }

    ulong expected;""")

    t = once(t, "module concurrency.research.p13_consumer;",
                  "module concurrency.research.p15_consumer;")
    t = once(t, "import concurrency.research.m1_scaling_kernel :",
                  "import concurrency.research.m1_p15_kernel :")
    t = once(t,
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum);""",
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum,
        ",", sample.p15Calls[0], ",", sample.p15WaitNs[0],
        ",", sample.p15HoldNs[0], ",", sample.p15MaxWaitNs[0],
        ",", sample.p15MaxHoldNs[0],
        ",", sample.p15Calls[1], ",", sample.p15WaitNs[1],
        ",", sample.p15HoldNs[1], ",", sample.p15MaxWaitNs[1],
        ",", sample.p15MaxHoldNs[1],
        ",", sample.p15Calls[2], ",", sample.p15WaitNs[2],
        ",", sample.p15HoldNs[2], ",", sample.p15MaxWaitNs[2],
        ",", sample.p15MaxHoldNs[2],
        ",", sample.p15Calls[3], ",", sample.p15WaitNs[3],
        ",", sample.p15HoldNs[3], ",", sample.p15MaxWaitNs[3],
        ",", sample.p15MaxHoldNs[3],
        ",", sample.p15Calls[4], ",", sample.p15WaitNs[4],
        ",", sample.p15HoldNs[4], ",", sample.p15MaxWaitNs[4],
        ",", sample.p15MaxHoldNs[4]);""")
    t = once(t,
        """        "retries,park_count,checksum");""",
        """        "retries,park_count,checksum,",
        "submit_calls,submit_wait_ns,submit_hold_ns,submit_max_wait_ns,submit_max_hold_ns,",
        "batch_calls,batch_wait_ns,batch_hold_ns,batch_max_wait_ns,batch_max_hold_ns,",
        "complete_calls,complete_wait_ns,complete_hold_ns,complete_max_wait_ns,complete_max_hold_ns,",
        "generation_calls,generation_wait_ns,generation_hold_ns,generation_max_wait_ns,generation_max_hold_ns,",
        "local_signal_calls,local_signal_wait_ns,local_signal_hold_ns,local_signal_max_wait_ns,local_signal_max_hold_ns");""")
    t = once(t,
        'stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",',
        'stderr.writeln("P15 M0 lock timing probe — diagnostic only; ",')
    for path, text in [
        (dest / "concurrency/research/m1_p15_kernel.d", s),
        (dest / "consumer/main.d", t),
    ]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// P15 GENERATED FROM REVIEWED P13; DO NOT EDIT.\n"
                        + text, encoding="utf8")
        print("P15 generated:", path)

if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("kernel", type=Path)
    a.add_argument("driver", type=Path)
    a.add_argument("destination", type=Path)
    opts = a.parse_args()
    generate(opts.kernel, opts.driver, opts.destination)
