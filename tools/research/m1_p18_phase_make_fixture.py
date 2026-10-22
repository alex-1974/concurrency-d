#!/usr/bin/env python3
"""P18 source-pinned *phase-boundary* driver for single-worker admission analysis.

Generated-only copies of the exact pinned P13 TaskRef kernel and driver.
No scheduler, task, retry, wake, locking or producer-yield policy changes.
A few timestamps and one acquire load per wave perturb measurements:
phase timings characterize those generated copies; NEVER merge their wall
times with the original uninstrumented ABBA throughput corpus.
"""
import argparse
from pathlib import Path
from tempfile import TemporaryDirectory

from m1_p18_make_fixture import generate as generate_p18, one, output


def generate(kernel, driver, race, destination):
    with TemporaryDirectory(prefix="p18-phase-source-") as temporary:
        temp = Path(temporary)
        generate_p18(kernel, driver, race, temp)
        k = (temp / "concurrency/research/m1_p18_kernel.d").read_text()
        d = (temp / "consumer/main.d").read_text()

    k = one(k,
        "module concurrency.research.m1_p18_kernel;",
        "module concurrency.research.m1_p18_phase_kernel;")
    d = one(d,
        "import concurrency.research.m1_p18_kernel :",
        "import concurrency.research.m1_p18_phase_kernel :")
    d = one(d,
        "module concurrency.research.p18_consumer;",
        "module concurrency.research.p18_phase_consumer;")

    k = one(k,
        "    long totalNs;\n}",
        """    long totalNs;
    // Sum over waves; phase measurement is separate from uninstrumented P18.
    long phaseFirstAcceptNs;       // before first accepted TaskRef
    long phaseSubmitNs;            // first accept to last admission
    long phaseCompletionWaitNs;    // last admission to wave completion
    long phaseResidualNs;          // outside the above wave intervals
    size_t phaseCompletedAtSubmit; // completed per-wave Tasks at last admission
}""")

    k = one(k,
        """        foreach (wave; 0 .. waves)
        {
            const deadline = MonoTime.currTime + dur!"seconds"(20);""",
        """        foreach (wave; 0 .. waves)
        {
            const phaseWaveStart = MonoTime.currTime.ticks;
            long phaseFirstAccepted = phaseWaveStart;
            const deadline = MonoTime.currTime + dur!"seconds"(20);""")

    k = one(k,
        """                    if (outcome == SubmissionResult.accepted)
                        break;""",
        """                    if (outcome == SubmissionResult.accepted)
                    {
                        if (j == 0)
                            phaseFirstAccepted = MonoTime.currTime.ticks;
                        break;
                    }""")

    k = one(k,
        """            // Wait until the last post-dispatch hook for this wave.
            // No record is reused or freed here; all stay rooted until""",
        """            // Only one extra acquire snapshot per completed wave:
            // How much of the wave had finished before its final admission?
            const phaseLastAccepted = MonoTime.currTime.ticks;
            const phaseCompletedAtSubmit =
                atomicLoad!(MemoryOrder.acq)(waveReturned[wave]);
            if (phaseCompletedAtSubmit > tasksPerWave)
                throw new Exception("P18 phase invalid completed-at-submit");

            // Wait until the last post-dispatch hook for this wave.
            // No record is reused or freed here; all stay rooted until""")

    k = one(k,
        """                Thread.yield();
            }
        }
        wavesFinished = MonoTime.currTime.ticks;""",
        """                Thread.yield();
            }
            const phaseWaveCompleted = MonoTime.currTime.ticks;
            sample.phaseFirstAcceptNs += elapsed(
                phaseWaveStart, phaseFirstAccepted);
            sample.phaseSubmitNs += elapsed(
                phaseFirstAccepted, phaseLastAccepted);
            sample.phaseCompletionWaitNs += elapsed(
                phaseLastAccepted, phaseWaveCompleted);
            sample.phaseCompletedAtSubmit += phaseCompletedAtSubmit;
        }
        wavesFinished = MonoTime.currTime.ticks;""")

    k = one(k,
        """    sample.wavesNs = elapsed(started, wavesFinished);
    sample.joinNs = elapsed(wavesFinished, joined);""",
        """    sample.wavesNs = elapsed(started, wavesFinished);
    const phaseAccounted = sample.phaseFirstAcceptNs
        + sample.phaseSubmitNs + sample.phaseCompletionWaitNs;
    if (phaseAccounted < 0 || phaseAccounted > sample.wavesNs ||
        sample.phaseCompletedAtSubmit > tasksPerWave * waves)
        throw new Exception("P18 phase boundary conservation failed");
    sample.phaseResidualNs = sample.wavesNs - phaseAccounted;
    sample.joinNs = elapsed(wavesFinished, joined);""")

    d = one(d,
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum);""",
        """        sample.retries, ",", sample.parkCount, ",", sample.checksum, ",",
        sample.phaseFirstAcceptNs, ",", sample.phaseSubmitNs, ",",
        sample.phaseCompletionWaitNs, ",", sample.phaseResidualNs, ",",
        sample.phaseCompletedAtSubmit);""")

    d = one(d,
        """        "retries,park_count,checksum");""",
        """        "retries,park_count,checksum,",
        "first_accept_ns,submit_span_ns,completion_wait_ns,",
        "phase_residual_ns,completed_at_submit");""")

    d = one(d,
        "P18 bounded idle grace RESEARCH only;",
        "P18 single-worker PHASE-boundary research only;")

    output(destination / "concurrency/research/m1_p18_phase_kernel.d", k)
    output(destination / "phase/consumer/main.d", d)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    parser.add_argument("driver", type=Path)
    parser.add_argument("race", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(args.kernel, args.driver, args.race, args.destination)
