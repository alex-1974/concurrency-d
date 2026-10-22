#!/usr/bin/env python3
"""Generate source-pinned executable M0/P18 Inbox park-boundary tests.

The ORIGINAL production module is NEVER edited. Two uniquely named RESEARCH
clones expose only an internal probe entry point. Every native test calls the
unchanged real TaskInbox generation/mutex/Condition implementation.
"""
from pathlib import Path
import argparse
import hashlib
from tempfile import TemporaryDirectory

from m1_p18_make_grace_pool import ORIGINAL_M0_BLOB, generate as make_grace, once

# Never put an essential publish/notification side effect solely inside
# D assert(): whole-release LDC can compile assertions away.
PROBE = r"""
private void requireParkBoundary(bool condition,
                                  string detail = "park boundary invariant")
{
    if (!condition)
        throw new Exception("P18 park boundary: " ~ detail);
}

// Research-only module-local access to the PRIVATE original TaskInbox.
// No change to generation, mutex, Condition, worker search or close logic.
// Any unreturned waiter is killed by the CI wrapper's external timeout.
void runP18ParkBoundaryProbe()
{
    import core.atomic : atomicStore, atomicLoad, MemoryOrder;

    // Publication before guard, including a foreign claim between submit
    // and guard (inbox empty but accepted obligation outstanding).
    foreach (capacity; [1u, 8u])
    {
        shared TaskHeader record;
        auto task = TaskRef(&record);
        {
            auto inbox = new TaskInbox(capacity);
            auto ticket = inbox.wakeGeneration();
            assert(inbox.trySubmit(task) == SubmissionResult.accepted);
            inbox.parkUnlessChanged(ticket); // must not sleep
            TaskRef[1] batch;
            assert(inbox.takeBatch(batch[]) == 1);
            inbox.completeOne();
            inbox.close();
            assert(inbox.isDrained());
        }
        {
            auto inbox = new TaskInbox(capacity);
            auto ticket = inbox.wakeGeneration();
            assert(inbox.trySubmit(task) == SubmissionResult.accepted);
            TaskRef[1] batch;
            assert(inbox.takeBatch(batch[]) == 1);
            // A foreign worker may claim the only TaskRef before the
            // previous worker reaches the generation guard.
            inbox.parkUnlessChanged(ticket); // must not sleep
            inbox.completeOne();
            inbox.close();
            assert(inbox.isDrained());
        }
        {
            auto inbox = new TaskInbox(capacity);
            auto ticket = inbox.wakeGeneration();
            inbox.announceLocalWork(); // publish to a worker-owned deque
            inbox.parkUnlessChanged(ticket); // generation changed
            inbox.close();
            assert(inbox.isDrained());
        }
        {
            auto inbox = new TaskInbox(capacity);
            auto ticket = inbox.wakeGeneration();
            inbox.close();
            inbox.parkUnlessChanged(ticket); // closed and drained
            assert(inbox.isDrained());
        }
        {
            auto inbox = new TaskInbox(capacity);
            shared uint done;
            const ticket = inbox.wakeGeneration();
            auto waiter = new Thread({
                inbox.parkUnlessChanged(ticket);
                atomicStore!(MemoryOrder.seq)(done, 1u);
            });
            waiter.start();
            // parkCount increments under the REAL mutex immediately
            // before wait; this method cannot acquire the mutex until
            // Condition.wait has atomically released it.
            bool entered;
            foreach (_; 0 .. 2_000_000)
            {
                if (inbox.parkCount() >= 1)
                {
                    entered = true;
                    break;
                }
                Thread.yield();
            }
            assert(entered, "native waiter never reached Condition.wait");
            assert(atomicLoad!(MemoryOrder.seq)(done) == 0u);
            // local queue publication uses generation+notify under the
            // SAME mutex; waiter must wake and re-check its predicate.
            inbox.announceLocalWork();
            bool woke;
            foreach (_; 0 .. 2_000_000)
            {
                if (atomicLoad!(MemoryOrder.seq)(done) == 1u)
                {
                    woke = true;
                    break;
                }
                Thread.yield();
            }
            assert(woke, "native Condition notify failed to wake waiter");
            waiter.join();
            inbox.close();
            assert(inbox.isDrained());
        }
        {
            auto inbox = new TaskInbox(capacity);
            shared uint done;
            auto ticket = inbox.wakeGeneration();
            auto waiter = new Thread({
                inbox.parkUnlessChanged(ticket);
                atomicStore!(MemoryOrder.seq)(done, 1u);
            });
            waiter.start();
            bool entered;
            foreach (_; 0 .. 2_000_000)
            {
                if (inbox.parkCount() >= 1)
                {
                    entered = true;
                    break;
                }
                Thread.yield();
            }
            assert(entered, "native close waiter never reached Condition");
            assert(atomicLoad!(MemoryOrder.seq)(done) == 0u);
            inbox.close(); // notifyAll and drained predicate
            waiter.join(); // external timeout protects from lost notification
            assert(atomicLoad!(MemoryOrder.seq)(done) == 1u);
            assert(inbox.isDrained());
        }
    }
}
"""

MAIN = """// GENERATED research-only runnable boundary test, no new public contract.
module concurrency.research.p18_park_boundary_main;

version (P18BoundaryGrace)
    import concurrency.research.m1_p18_boundary_grace_pool :
        runP18ParkBoundaryProbe;
else
    import concurrency.research.m1_p18_boundary_control_pool :
        runP18ParkBoundaryProbe;

import std.stdio : writeln;
void main()
{
    foreach (_; 0 .. 8)
        runP18ParkBoundaryProbe();
    writeln("P18_PARK_BOUNDARY_PASS scenarios=96");
}
"""


def checked_original(path):
    raw = path.read_bytes()
    actual = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if actual != ORIGINAL_M0_BLOB:
        raise ValueError(f"M0 source drift {actual}")
    return raw.decode("utf-8")


def generate(original, destination):
    m0 = checked_original(original)
    with TemporaryDirectory(prefix="p18-boundary-source-") as tmp:
        grace = Path(tmp) / "m1_p18_grace_pool.d"
        make_grace(original, grace)
        grace_source = grace.read_text(encoding="utf-8")

    m0 = once(m0, "module concurrency.internal.submission_pool;",
              "module concurrency.research.m1_p18_boundary_control_pool;")
    grace_source = once(
        grace_source,
        "module concurrency.research.m1_p18_grace_pool;",
        "module concurrency.research.m1_p18_boundary_grace_pool;")
    prefix = "// GENERATED SOURCE-PINNED RESEARCH TEST; NOT PRODUCTION.\n"
    # Ensure ALL 16 research assertions are converted to always-executed
    # checks; failing to do this invalidates -release semantics.
    if PROBE.count("assert(") != 16:
        raise RuntimeError("native park boundary assertion site drift")
    probe = PROBE.replace("assert(", "requireParkBoundary(")
    outputs = (
        (destination / "concurrency/research/m1_p18_boundary_control_pool.d",
         prefix + m0 + probe),
        (destination / "concurrency/research/m1_p18_boundary_grace_pool.d",
         prefix + grace_source + probe),
        (destination / "boundary/main.d", MAIN),
    )
    for path, contents in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        print("P18 boundary generated:", path)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("original", type=Path)
    ap.add_argument("destination", type=Path)
    x = ap.parse_args()
    generate(x.original, x.destination)
