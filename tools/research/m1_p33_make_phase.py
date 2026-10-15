#!/usr/bin/env python3
"""P33: generate a phase-observing P31 consumer from an immutable Git blob.

Only producer timing/barrier and CSV telemetry are changed. The M0 executor,
P23 owner, P29 manager, worker dispatch, and task work stay source-identical.
"""
import hashlib
from pathlib import Path
import argparse

PIN = "d19405f2ef0f8d7159978174c1a919ed6d66764f"


def once(s, a, b):
    if s.count(a) != 1:
        raise RuntimeError(f"P33 drift in anchor ({s.count(a)}): {a[:100]!r}")
    return s.replace(a, b, 1)


def generate(source: Path, dest: Path):
    raw = source.read_bytes()
    observed = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    if observed != PIN:
        raise RuntimeError(f"P33 source drift: {observed} != {PIN}")
    s = raw.decode()
    s = once(s, "module concurrency.research.p29_generational_owner;",
             "module concurrency.research.p33_generational_owner;")
    s = once(s, "version (P31Benchmark)\n{\n    import concurrency.internal.owned_task :",
             "version (P31Benchmark)\n{\n    import concurrency.internal.owned_task :")
    s = once(s, """    private final class P31Stats
    {
        size_t attempts;
        size_t accepted;
        size_t producerBytes;
    }""", """    private final class P31Stats
    {
        size_t attempts;
        size_t accepted;
        size_t producerBytes;
        long readyTicks;
        long enteredTicks;
        long finishedTicks;
    }

    // A shared start gate changes scheduling, so compare P33Phase with the
    // original P31 consumer and do not reinterpret intervals as pure costs.
    private final class P33Gate
    {
        shared size_t ready;
        Semaphore go;
        this() { go = new Semaphore(0); }
    }""")
    s = once(s, """        OwnerHandle h, P31Counter counter, size_t count,
        P31Stats stats)
    {
        return new Thread({
            P31CountedJob counted;""", """        OwnerHandle h, P31Counter counter, size_t count,
        P31Stats stats, P33Gate gate)
    {
        return new Thread({
            P31CountedJob counted;""")
    s = once(s, """            P31MinimalJob minimal;
            const startBytes = GC.allocatedInCurrentThread();""", """            P31MinimalJob minimal;
            stats.readyTicks = MonoTime.currTime.ticks;
            atomicFetchAdd!(MemoryOrder.rel)(gate.ready, cast(size_t)1);
            gate.go.wait();
            stats.enteredTicks = MonoTime.currTime.ticks;
            const startBytes = GC.allocatedInCurrentThread();""")
    s = once(s, """            stats.producerBytes = endBytes >= startBytes
                ? endBytes - startBytes : 0;
        });
    }""", """            stats.producerBytes = endBytes >= startBytes
                ? endBytes - startBytes : 0;
            stats.finishedTicks = MonoTime.currTime.ticks;
        });
    }""")
    s = once(s, """        auto threads = new Thread[producers];
        auto stats = new P31Stats[producers];""", """        const prepStart = MonoTime.currTime;
        auto gate = new P33Gate();
        auto threads = new Thread[producers];
        auto stats = new P31Stats[producers];""")
    s = once(s, """                manager, h, counter, taskCount / producers, stats[i]);
        }
        foreach (t; threads)
            launchOrAbort(t);
        foreach (t; threads)
            joinOrAbort(t);
        const submitted = MonoTime.currTime;""", """                manager, h, counter, taskCount / producers, stats[i], gate);
        }
        const prepared = MonoTime.currTime;
        foreach (t; threads)
            launchOrAbort(t);
        const launched = MonoTime.currTime;
        // All started producers have acknowledged reaching this gate.
        // A timeout must NOT unwind owned TaskRefs or running workers.
        const deadline = MonoTime.currTime + dur!"seconds"(30);
        while (atomicLoad!(MemoryOrder.acq)(gate.ready) != producers)
        {
            if (MonoTime.currTime > deadline)
                abort();
            Thread.yield();
        }
        const reached = MonoTime.currTime;
        foreach (_; 0 .. producers)
            gate.go.notify();
        const released = MonoTime.currTime;
        foreach (t; threads)
            joinOrAbort(t);
        const submitted = MonoTime.currTime;
        long firstEntry = long.max, lastFinish;
        foreach (stat; stats)
        {
            check(stat.enteredTicks >= stat.readyTicks &&
                  stat.finishedTicks >= stat.enteredTicks,
                  "P33 invalid thread-local monotonic timing");
            if (stat.enteredTicks < firstEntry)
                firstEntry = stat.enteredTicks;
            if (stat.finishedTicks > lastFinish)
                lastFinish = stat.finishedTicks;
        }
        check(lastFinish >= firstEntry &&
              prepared >= prepStart && launched >= prepared &&
              reached >= launched && released >= reached,
              "P33 invalid phase boundaries");""")
    s = once(s, """            (stopped - submitted).total!"nsecs", ",",
            (stopped - begin).total!"nsecs");
    }""", """            (stopped - submitted).total!"nsecs", ",",
            (stopped - begin).total!"nsecs", ",",
            (prepared - prepStart).total!"nsecs", ",",
            (launched - prepared).total!"nsecs", ",",
            (reached - launched).total!"nsecs", ",",
            (released - reached).total!"nsecs", ",",
            (submitted - released).total!"nsecs", ",",
            (stopped - submitted).total!"nsecs");
    }""")
    s = once(s, """            ~ "join_release_ns,total_ns");""", """            ~ "join_release_ns,total_ns,"
            ~ "prepare_ns,launch_ns,reach_gate_ns,release_ns,"
            ~ "submit_after_gate_ns,worker_join_ns");""")
    s = once(s, 'writeln("P31_FIXED_DIMENSIONS_BENCHMARK_PASS");',
             'writeln("P33_PHASE_BENCHMARK_PASS");')
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("// P33 GENERATED FROM PINNED P31; RESEARCH ONLY\n" + s)
    print("P33_GENERATED_PINNED_P31", dest)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    generate(a.source, a.output)
