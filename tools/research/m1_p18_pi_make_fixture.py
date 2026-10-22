#!/usr/bin/env python3
"""Source-pin P18 single-worker producer/ingress event-only TaskRef consumer.

The original P13 driver/kernel and existing trace generator remain unchanged.
No traced wall-clock values may be used as scheduler performance evidence.
"""
import argparse
from pathlib import Path
import tempfile

from m1_p18_512_make_trace_fixture import generate as generate_trace
from m1_p18_pi_make_pair import FIELDS


def one(s, old, new, count=1):
    observed = s.count(old)
    if observed != count:
        raise RuntimeError(f"P18 PI driver source anchor mismatch {observed}/{count}: {old[:100]!r}")
    return s.replace(old, new, count)


def field(name):
    return "p18Pi" + name[0].upper() + name[1:]


def generate(kernel, driver, destination):
    with tempfile.TemporaryDirectory(prefix="p18-pi-exact-driver-") as temp:
        root = Path(temp)
        generate_trace(kernel, driver, root)
        s = (root / "concurrency/research/m1_p18_trace_kernel.d").read_text()
        t = (root / "trace/consumer/main.d").read_text()

    s = one(s,
        "module concurrency.research.m1_p18_trace_kernel;",
        "module concurrency.research.m1_p18_pi_kernel;")
    for mode in ("control", "grace"):
        s = one(s,
            f"concurrency.research.m1_p18_trace_{mode}_pool",
            f"concurrency.research.m1_p18_pi_{mode}_pool")

    declarations = "".join(f"    ulong {field(x)};\n" for x in FIELDS)
    declarations += "    ulong p18PiPollYields;\n"
    s = one(s,
        "    ulong p18MaxWorkerTasks;\n    long prepareNs;",
        "    ulong p18MaxWorkerTasks;\n" + declarations + "    long prepareNs;")

    checks = """ev.submitAccepted != all ||
            ev.submitClosed != 0 ||
            ev.submitCalls != ev.submitAccepted + ev.submitFull + ev.submitClosed ||
            ev.submitFull != sample.retries ||
            ev.takeCalls < ev.takeEmpty ||
            ev.takeCalls - ev.takeEmpty != ev.batchClaims ||
            ev.takenTasks != all ||
            ev.takenTasks != ev.batchTasks ||
            ev.completeCalls != all ||
            ev.acceptOccupancy1to8 + ev.acceptOccupancy9to256 +
                ev.acceptOccupancy257Plus != ev.submitAccepted ||
            ev.peakUsed > ingress ||
            ev.peakUsed == 0 ||
            (ev.submitFull != 0 && ev.peakUsed != ingress) ||
            (ingress >= tasksPerWave && ev.submitFull != 0) ||
            """
    s = one(s, "ev.workerCount != workers ||",
            checks + "ev.workerCount != workers ||", count=2)

    assignments = "".join(
        f"        sample.{field(x)} = ev.{x};\n" for x in FIELDS
    )
    s = one(s,
        "        sample.p18MaxWorkerTasks = high;",
        "        sample.p18MaxWorkerTasks = high;\n" + assignments.rstrip("\n"),
        count=2)

    s = one(s,
        """                if (MonoTime.currTime > deadline)
                    throw new Exception("P13 completion wave timeout");
                Thread.yield();""",
        """                if (MonoTime.currTime > deadline)
                    throw new Exception("P13 completion wave timeout");
                ++sample.p18PiPollYields;
                Thread.yield();""")

    t = one(t,
        "module concurrency.research.p18_trace_consumer;",
        "module concurrency.research.p18_pi_consumer;")
    t = one(t,
        "import concurrency.research.m1_p18_trace_kernel :",
        "import concurrency.research.m1_p18_pi_kernel :")
    t = one(t,
        'options.profile != "smoke" && options.profile != "native" && options.profile != "focus512"',
        'options.profile != "smoke" && options.profile != "native" && options.profile != "focus512" && options.profile != "singleingress"')
    t = one(t,
        'const size_t[] workers = [1, 2, 4];',
        'const size_t[] workers = profile == "singleingress" ? [1] : [1, 2, 4];')
    t = one(t,
        '? [0, 128] : profile == "focus512" ? [128, 512, 1024] : [0, 8, 32, 128, 512];',
        '? [0, 128] : profile == "focus512" || profile == "singleingress" ? [128, 512, 1024] : [0, 8, 32, 128, 512];')
    t = one(t,
        '? [64] : [8, 64, 256];',
        '? [64] : profile == "singleingress" ? [8, 64, 256, 2048] : [8, 64, 256];')

    values = "".join(
        f', ",", sample.{field(name)}' for name in FIELDS
    ) + ', ",", sample.p18PiPollYields'
    t = one(t,
        'sample.p18MaxWorkerTasks);',
        'sample.p18MaxWorkerTasks' + values + ');')
    columns = ",".join(FIELDS) + ",pollYields"
    t = one(t,
        '"local_hits,local_misses,min_worker_tasks,max_worker_tasks");',
        f'"local_hits,local_misses,min_worker_tasks,max_worker_tasks,{columns}");')
    t = one(t,
        "P18 scheduler-event study is DIAGNOSTIC ONLY;",
        "P18 producer/ingress event study is DIAGNOSTIC ONLY;")

    for name, contents in (
        ("concurrency/research/m1_p18_pi_kernel.d", s),
        ("pi/consumer/main.d", t),
    ):
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf8")
        print("P18 PI generated", path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("driver", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(args.kernel, args.driver, args.destination)
