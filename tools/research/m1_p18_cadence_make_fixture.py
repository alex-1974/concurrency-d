#!/usr/bin/env python3
"""Generate research-only, EXACT-P13-derived producer success-yield cadence.

Native control/grace remain compiled from the untouched P18 benchmark module.
Paced variants do not alter TaskRef, retry-on-full, completion polling, pool
worker, close/join, record layout or task kernel. Additional yields are an
INTENTIONAL change to the *producer workload*, not a scheduler improvement.
No hot-path timestamps, extra locks, counter increments, or tracepoints.
"""
from pathlib import Path
from tempfile import TemporaryDirectory
import argparse

from m1_p18_make_fixture import generate as pinned_fixture, one, output


def generate(kernel, driver, race, destination):
    with TemporaryDirectory(prefix="p18-cadence-original-") as temp:
        root = Path(temp)
        pinned_fixture(kernel, driver, race, root)
        k = (root / "concurrency/research/m1_p18_kernel.d").read_text()
        d = (root / "consumer/main.d").read_text()

    k = one(k, "module concurrency.research.m1_p18_kernel;",
        """module concurrency.research.m1_p18_cadence_kernel;

// Only a generated research benchmark: compile-time separated workloads.
version (P18Cadence8)
    private enum size_t P18ProducerCadence = 8;
else version (P18Cadence64)
    private enum size_t P18ProducerCadence = 64;
else
    static assert(0, "P18 cadence benchmark requires explicit cadence version");
""")
    k = one(k,
        """                    if (outcome == SubmissionResult.accepted)
                        break;""",
        """                    if (outcome == SubmissionResult.accepted)
                    {
                        // Intentional producer-only pacing AFTER a successful
                        // admission, never after the final TaskRef in a wave.
                        // The original full-inbox retry policy is unchanged.
                        if (j + 1 < tasksPerWave &&
                            ((j + 1) % P18ProducerCadence) == 0)
                            Thread.yield();
                        break;
                    }""")
    d = one(d, "module concurrency.research.p18_consumer;",
        "module concurrency.research.p18_cadence_consumer;")
    d = one(d, "import concurrency.research.m1_p18_kernel :",
        "import concurrency.research.m1_p18_cadence_kernel :")
    d = one(d, "P18 bounded idle grace RESEARCH only;",
        "P18 deliberately paced producer research (8/64 successes);")

    # Report the exact deterministic number of extra producer yields outside
    # the hot-path loop; this is NOT an atomic measurement or tracing clock.
    k = one(k, "    size_t parkCount;\n    ulong checksum;",
        "    size_t parkCount;\n    size_t cadenceYields;\n    ulong checksum;")
    k = one(k,
        "    sample.ingress = ingress;\n    const all = tasksPerWave * waves;",
        """    sample.ingress = ingress;
    sample.cadenceYields = waves * ((tasksPerWave - 1) / P18ProducerCadence);
    const all = tasksPerWave * waves;""")
    d = one(d,
        "sample.retries, \",\", sample.parkCount, \",\", sample.checksum);",
        "sample.retries, \",\", sample.parkCount, \",\", sample.checksum, \",\", sample.cadenceYields);")
    d = one(d,
        '"retries,park_count,checksum");',
        '"retries,park_count,checksum,cadence_yields");')

    output(destination / "concurrency/research/m1_p18_cadence_kernel.d", k)
    output(destination / "cadence/consumer/main.d", d)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("kernel", type=Path)
    p.add_argument("driver", type=Path)
    p.add_argument("race", type=Path)
    p.add_argument("destination", type=Path)
    a = p.parse_args()
    generate(a.kernel, a.driver, a.race, a.destination)
