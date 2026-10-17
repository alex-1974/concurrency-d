#!/usr/bin/env python3
"""P18 PI research: extend EXACT source-pinned M0/P18 event copies.

Every new counter is incremented only under the original TaskInbox mutex.
No lock/yield policy, hot-path timing, production source or public API changes.
The base P18 generator independently verifies the exact original M0 blob and
byte-identical P18 candidate before instrumentation.
"""
import argparse
from pathlib import Path
import tempfile

from m1_p18_512_make_event_pair import instrument


def one(source, before, after):
    n = source.count(before)
    if n != 1:
        raise RuntimeError(
            f"P18 producer/ingress source anchor mismatch ({n}): {before[:100]!r}")
    return source.replace(before, after, 1)


FIELDS = (
    "submitCalls", "submitAccepted", "submitFull", "submitClosed",
    "takeCalls", "takeEmpty", "takenTasks", "peakUsed",
    "acceptOccupancy1to8", "acceptOccupancy9to256",
    "acceptOccupancy257Plus", "completeCalls", "wakeReads",
    "drainReads", "announceCalls",
)


def generate(kind, original, destination):
    with tempfile.TemporaryDirectory(prefix="p18-pi-exact-") as scratch:
        intermediate = Path(scratch) / "source.d"
        instrument(original, intermediate, kind)
        text = intermediate.read_text(encoding="utf8")

    text = one(
        text,
        f"module concurrency.research.m1_p18_trace_{kind}_pool;",
        f"module concurrency.research.m1_p18_pi_{kind}_pool;")

    text = one(
        text,
        "    size_t workerCount;\n    ulong localHits;",
        "    size_t workerCount;\n" +
        "".join(f"    ulong {name};\n" for name in FIELDS) +
        "    ulong localHits;")

    text = one(
        text,
        "    private size_t _p18ParkWithOutstanding;\n    private bool _closed;",
        "    private size_t _p18ParkWithOutstanding;\n" +
        "".join(f"    private ulong _p18Pi{name[0].upper() + name[1:]};\n"
                for name in FIELDS) +
        "    private bool _closed;")

    text = one(
        text,
        """        synchronized (_mutex)
        {
            if (_closed)
                return SubmissionResult.closed;

            if (_used == _slots.length)
                return SubmissionResult.full;""",
        """        synchronized (_mutex)
        {
            ++_p18PiSubmitCalls;
            if (_closed)
            {
                ++_p18PiSubmitClosed;
                return SubmissionResult.closed;
            }

            if (_used == _slots.length)
            {
                ++_p18PiSubmitFull;
                return SubmissionResult.full;
            }""")

    text = one(
        text,
        """            ++_used;
            ++_accepted;
            ++_generation;""",
        """            ++_used;
            ++_accepted;
            ++_p18PiSubmitAccepted;
            if (_used > _p18PiPeakUsed)
                _p18PiPeakUsed = _used;
            if (_used <= 8)
                ++_p18PiAcceptOccupancy1to8;
            else if (_used <= 256)
                ++_p18PiAcceptOccupancy9to256;
            else
                ++_p18PiAcceptOccupancy257Plus;
            ++_generation;""")

    text = one(
        text,
        """    size_t takeBatch(scope TaskRef[] output)
    {
        synchronized (_mutex)
        {
            size_t taken;""",
        """    size_t takeBatch(scope TaskRef[] output)
    {
        synchronized (_mutex)
        {
            ++_p18PiTakeCalls;
            size_t taken;""")

    text = one(
        text,
        """                ++taken;
            }

            return taken;""",
        """                ++taken;
            }

            _p18PiTakenTasks += taken;
            if (taken == 0)
                ++_p18PiTakeEmpty;
            return taken;""")

    text = one(
        text,
        """            ++_completed;

            // The final completion""",
        """            ++_completed;
            ++_p18PiCompleteCalls;

            // The final completion""")

    text = one(
        text,
        """    size_t wakeGeneration()
    {
        synchronized (_mutex)
        {
            return _generation;""",
        """    size_t wakeGeneration()
    {
        synchronized (_mutex)
        {
            ++_p18PiWakeReads;
            return _generation;""")

    text = one(
        text,
        """    bool isDrained()
    {
        synchronized (_mutex)
        {
            return _closed &&""",
        """    bool isDrained()
    {
        synchronized (_mutex)
        {
            ++_p18PiDrainReads;
            return _closed &&""")

    text = one(
        text,
        """    void announceLocalWork()
    {
        synchronized (_mutex)
        {
            ++_generation;""",
        """    void announceLocalWork()
    {
        synchronized (_mutex)
        {
            ++_p18PiAnnounceCalls;
            ++_generation;""")

    text = one(
        text,
        """            result.parkWaitsWithOutstanding = _p18ParkWithOutstanding;""",
        """            result.parkWaitsWithOutstanding = _p18ParkWithOutstanding;
""" + "".join(
            f"            result.{name} = _p18Pi{name[0].upper() + name[1:]};\n"
            for name in FIELDS).rstrip("\n"))

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        "// GENERATED P18 PRODUCER-INGRESS EVENT-ONLY; NO PRODUCTION EDIT.\n"
        + text, encoding="utf8")
    print("P18 PI source-pinned", kind, destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("control", "grace"))
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(args.kind, args.source, args.destination)
