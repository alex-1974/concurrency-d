#!/usr/bin/env python3
"""Generate an exact-source P16.2 research-only M0 atomic completion variant.

No writes to production source. Source SHA/each replacement fail closed.
Seq-Cst completion/closed handshake is chosen for an auditable no-lost-final-
wake proof; do NOT casually weaken orders based on codegen benchmarks.
"""
import argparse
import hashlib
from pathlib import Path

M0_BLOB = "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def replace_one(s, old, new):
    occurrences = s.count(old)
    if occurrences != 1:
        raise RuntimeError(f"P16.2 source drift: {occurrences} copies of {old[:110]!r}")
    return s.replace(old, new, 1)

def generate(src, dest):
    raw = src.read_bytes()
    digest = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if digest != M0_BLOB:
        raise RuntimeError(f"P16.2 M0 Git blob changed: {digest}, expected {M0_BLOB}")
    c = raw.decode("utf-8")
    c = replace_one(c,
        "module concurrency.internal.submission_pool;",
        """module concurrency.research.m1_p16_2_pool;

// Research-only split between frequent completed-accounting and rare
// closed-state wakeup. All fast handshake operations use SEQ_CST order.
// Ordinary inbox queue and generation/Condition protocol remain mutex-owned.
import core.atomic : atomicStore;
""")
    c = replace_one(c,
        """    private size_t _accepted;
    private size_t _completed;
    private size_t _generation;""",
        """    private size_t _accepted;
    // _accepted is still serialized with inbox publication. This atomically
    // published mirror allows the original completed<accepted assertion to
    // remain meaningful without acquiring the mutex on every completion.
    private shared size_t _acceptedPublished;
    private shared size_t _completedAtomic;
    private shared uint _closedFast;
    private size_t _generation;""")
    c = replace_one(c,
        """            ++_accepted;
            ++_generation;""",
        """            ++_accepted;
            atomicStore!(MemoryOrder.seq)(_acceptedPublished, _accepted);
            ++_generation;""")
    c = replace_one(c,
        """    void completeOne()
    {
        synchronized (_mutex)
        {
            assert(_completed < _accepted);
            ++_completed;

            // The final completion releases all workers waiting for the
            // shutdown predicate. Earlier completions introduce no work.
            if (_closed && _completed == _accepted)
            {
                ++_generation;
                _changed.notifyAll();
            }
        }
    }""",
        """    void completeOne()
    {
        // Accounting for EVERY task must precede the optional close check
        // in the single global seq-cst order. No mutex on the open fast path.
        const previous =
            atomicFetchAdd!(MemoryOrder.seq)(_completedAtomic, cast(size_t) 1);
        assert(previous < atomicLoad!(MemoryOrder.seq)(_acceptedPublished));

        // This load forms one side of the two-location seq-cst handshake
        // with close(): either close sees this increment, or this completion
        // sees the published close flag. Otherwise join could deadlock.
        if (atomicLoad!(MemoryOrder.seq)(_closedFast) != 0u)
        {
            synchronized (_mutex)
            {
                // All accepted obligations are fixed after close. Hold the
                // Condition mutex while checking the final predicate AND
                // notifying sleepers. Redundant final broadcasts are benign.
                if (_closed &&
                    atomicLoad!(MemoryOrder.seq)(_completedAtomic) == _accepted)
                {
                    ++_generation;
                    _changed.notifyAll();
                }
            }
        }
    }""")
    c = replace_one(c,
        """            _closed = true;
            ++_generation;
            _changed.notifyAll();""",
        """            _closed = true;
            atomicStore!(MemoryOrder.seq)(_closedFast, 1u);
            ++_generation;
            _changed.notifyAll();
            // close's seq-cst load is the other half of the handshake.
            // The existing broadcast already makes this safe if all
            // completions happened before close.
            const completedNow =
                atomicLoad!(MemoryOrder.seq)(_completedAtomic);
            assert(completedNow <= _accepted);""")
    c = replace_one(c,
        """                   !(_closed && _completed == _accepted))""",
        """                    !(_closed &&
                      atomicLoad!(MemoryOrder.seq)(_completedAtomic) == _accepted))""")
    c = replace_one(c,
        """            return _closed &&
                _used == 0 &&
                _completed == _accepted;""",
        """            return _closed &&
                _used == 0 &&
                atomicLoad!(MemoryOrder.seq)(_completedAtomic) == _accepted;""")
    c = replace_one(c,
        """    size_t completedCount()
    {
        synchronized (_mutex)
        {
            return _completed;
        }
    }""",
        """    size_t completedCount()
    {
        synchronized (_mutex)
        {
            return atomicLoad!(MemoryOrder.seq)(_completedAtomic);
        }
    }""")
    if "_completed ==" in c or "++_completed;" in c:
        raise RuntimeError("P16.2 stale original completion access found")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(
        "// GENERATED P16.2 RESEARCH; NO PRODUCTION EDIT.\n"
        f"// Original M0 Git blob {M0_BLOB}\n" + c, encoding="utf-8"
    )
    print("P16.2 exact M0 source variant generated:", dest)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    ap.add_argument("destination", type=Path)
    a = ap.parse_args()
    generate(a.source, a.destination)
