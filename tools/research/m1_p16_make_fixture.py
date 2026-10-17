#!/usr/bin/env python3
"""P16.1: build exactly the same P13 multi-wave consumer for three modes.

Mode A imports untouched M0; B reads two clocks before sampled completeOne;
C brackets sampled completeOne with clocks. All work, results, native joins,
lifetime and backpressure stay exactly the same. Git blobs pinned strictly.
"""
import argparse
import hashlib
from pathlib import Path

KERNEL_BLOB = "3852e8788757b62c5000ad55565359d6a20a78c1"
DRIVER_BLOB = "723de6bf76ac838b10de4b3f1cb901315a5ced38"

def checked(path, expected):
    raw = path.read_bytes()
    actual = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if actual != expected:
        raise RuntimeError(f"P16 P13 source drift in {path}: {actual} != {expected}")
    return raw.decode()

def once(s, old, new):
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f"P16 missing/ambiguous source anchor ({n}): {old[:88]!r}")
    return s.replace(old, new, 1)

def generate(kernel, driver, root):
    s = checked(kernel, KERNEL_BLOB)
    t = checked(driver, DRIVER_BLOB)
    s = once(s, "module concurrency.research.m1_scaling_kernel;",
             "module concurrency.research.m1_p16_kernel;")
    s = once(s,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P16Measured)
{
    import concurrency.research.m1_p16_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    version (P16NullProbe)
    {
        import concurrency.research.m1_p16_pool :
            SubmissionResult, SubmissionWorkerPool;
    }
    else
    {
        import concurrency.internal.submission_pool :
            SubmissionResult, SubmissionWorkerPool;
    }
}""")
    s = once(s, "    ulong checksum;\n    long prepareNs;",
        """    ulong checksum;
    ulong p16Calls;
    ulong p16Samples;
    ulong p16DurationNs;
    ulong p16MaxNs;
    ulong p16Anomalies;
    long prepareNs;""")
    metric_check = """        auto snap = pool.p16Snapshot();
        if (snap.workerCount != workers || snap.calls != all ||
            snap.clockAnomalies != 0 ||
            (all >= 64 * workers && snap.samples == 0) ||
            snap.maxNs > snap.durationNs)
            throw new Exception("P16 sampled completion accounting failure");
        ulong totalWorkerCalls;
        ulong totalWorkerSamples;
        foreach (i; 0 .. workers)
        {
            totalWorkerCalls += snap.perWorkerCalls[i];
            totalWorkerSamples += snap.perWorkerSamples[i];
            if (snap.perWorkerSamples[i] != snap.perWorkerCalls[i] / 64)
                throw new Exception("P16 per-worker sampling period mismatch");
        }
        if (totalWorkerCalls != all || totalWorkerSamples != snap.samples)
            throw new Exception("P16 per-worker conservation failure");
        sample.p16Calls = snap.calls;
        sample.p16Samples = snap.samples;
        sample.p16DurationNs = snap.durationNs;
        sample.p16MaxNs = snap.maxNs;
        sample.p16Anomalies = snap.clockAnomalies;"""
    s = once(s,
        """    sample.parkCount = pool.parkCount();

    ulong expected;""",
        """    sample.parkCount = pool.parkCount();
    version (P16NullProbe)
    {
""" + metric_check + """
    }
    version (P16Measured)
    {
""" + metric_check + """
    }

    ulong expected;""")
    t = once(t, "module concurrency.research.p13_consumer;",
             "module concurrency.research.p16_consumer;")
    t = once(t, "import concurrency.research.m1_scaling_kernel :",
             "import concurrency.research.m1_p16_kernel :")
    t = once(t,
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum);""",
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum,
        ",", sample.p16Calls, ",", sample.p16Samples, ",",
        sample.p16DurationNs, ",", sample.p16MaxNs, ",",
        sample.p16Anomalies);""")
    t = once(t,
        """        "retries,park_count,checksum");""",
        """        "retries,park_count,checksum,",
        "sample_calls,sample_count,sample_sum_ns,sample_max_ns,",
        "sample_anomalies");""")
    t = once(t,
        'stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",',
        'stderr.writeln("P16 lower-impact completion sampling is research only; ",')
    for relative, data in [
        ("concurrency/research/m1_p16_kernel.d", s),
        ("consumer/main.d", t),
    ]:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("// P16 AUTO-GENERATED FROM REVIEWED P13; NO HAND EDITS.\n"
                          + data, encoding="utf8")
        print("P16 generated:", target)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("kernel", type=Path)
    ap.add_argument("driver", type=Path)
    ap.add_argument("destination", type=Path)
    a = ap.parse_args()
    generate(a.kernel, a.driver, a.destination)
