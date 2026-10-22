#!/usr/bin/env python3
"""P18 identical P13 benchmark and original P16.2 adversarial race consumer.

All source blobs are pinned. Original real M0 vs ONLY one worker-local,
one-time idle-search retry variant; same tasks/results/joins/close semantics.
"""
import argparse
import hashlib
from pathlib import Path

KERNEL = "3852e8788757b62c5000ad55565359d6a20a78c1"
DRIVER = "723de6bf76ac838b10de4b3f1cb901315a5ced38"
RACE = "f158e14ef7a69cff1d2a5005090926794a5846ce"

def checked(path, expected):
    raw = path.read_bytes()
    digest = hashlib.sha1(f"blob {len(raw)}\0".encode()+raw).hexdigest()
    if digest != expected:
        raise RuntimeError(f"P18 fixture source changed: {path}: {digest}")
    return raw.decode("utf8")

def one(s, a, b):
    n = s.count(a)
    if n != 1:
        raise RuntimeError(f"P18 source anchor count {n}: {a[:105]!r}")
    return s.replace(a, b, 1)

def output(path, s):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("// GENERATED P18 PINNED WORKLOAD; RESEARCH ONLY.\n"+s)
    print("P18 fixture generated:", path)

def generate(kernel, driver, race, target):
    k = checked(kernel, KERNEL)
    d = checked(driver, DRIVER)
    a = checked(race, RACE)
    k = one(k, "module concurrency.research.m1_scaling_kernel;",
               "module concurrency.research.m1_p18_kernel;")
    k = one(k,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P18Grace)
{
    import concurrency.research.m1_p18_grace_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}""")
    d = one(d, "module concurrency.research.p13_consumer;",
            "module concurrency.research.p18_consumer;")
    d = one(d, "import concurrency.research.m1_scaling_kernel :",
            "import concurrency.research.m1_p18_kernel :")
    # Focused larger-work kernel family. Only the generated P18 driver is
    # extended; the exact source-checked P13 driver remains unchanged.
    d = one(d,
        'options.profile != "smoke" && options.profile != "native"',
        'options.profile != "smoke" && options.profile != "native" && options.profile != "long" && options.profile != "focus512" && options.profile != "singleingress" && options.profile != "sched8" && options.profile != "sched2048"')
    d = one(d,
        '? [0, 128] : [0, 8, 32, 128, 512];',
        '? [0, 128] : profile == "long" ? [128, 256, 512, 1024, 2048] : profile == "focus512" || profile == "singleingress" ? [128, 512, 1024] : profile == "sched8" || profile == "sched2048" ? [512] : [0, 8, 32, 128, 512];')
    # One real worker removes the stealing path entirely. A 2048-slot
    # ingress can admit a full 2048-TaskRef wave without any producer-full
    # retries; 8/64/256 retain producer backpressure and yield behavior.
    # These modifications apply only to the generated research driver.
    d = one(d,
        'const size_t[] workers = [1, 2, 4];',
        'const size_t[] workers = profile == "singleingress" || profile == "sched8" || profile == "sched2048" ? [1] : [1, 2, 4];')
    d = one(d,
        '? [64] : [8, 64, 256];',
        '? [64] : profile == "singleingress" ? [8, 64, 256, 2048] : profile == "sched8" ? [8] : profile == "sched2048" ? [2048] : [8, 64, 256];')
    d = one(d,
        'stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",'
,
        'stderr.writeln("P18 bounded idle grace RESEARCH only; ",')
    a = one(a, "module concurrency.research.p16_2_close_races;",
            "module concurrency.research.p18_close_races;")
    a = one(a, "version (P162Atomic)", "version (P18Grace)")
    a = one(a, "concurrency.research.m1_p16_2_pool :",
            "concurrency.research.m1_p18_grace_pool :")
    output(target/"concurrency/research/m1_p18_kernel.d", k)
    output(target/"consumer/main.d", d)
    output(target/"race/main.d", a)

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("kernel",type=Path)
    p.add_argument("driver",type=Path)
    p.add_argument("race",type=Path)
    p.add_argument("destination",type=Path)
    a=p.parse_args()
    generate(a.kernel,a.driver,a.race,a.destination)
