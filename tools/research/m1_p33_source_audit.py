#!/usr/bin/env python3
"""P33 source-anchored preflight: refuse to decompose a drifted P31 consumer.

This checks the exact research input and expected timing boundaries. It does
NOT produce experimental results or qualify any runtime memory-model change.
"""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REL = "research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d"
BLOB = "d19405f2ef0f8d7159978174c1a919ed6d66764f"


def blob_sha(raw):
    return hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()


def check_source(raw):
    observed = blob_sha(raw)
    if observed != BLOB:
        raise ValueError(f"P33 P31 consumer drift: {observed} != {BLOB}")
    text = raw.decode("utf-8")
    section = text.split("else version (P31Benchmark)", 1)
    if len(section) != 2:
        raise ValueError("P33 missing exact P31 benchmark branch")
    sample = section[1].split("else version (P29ExitUnknown)", 1)
    if len(sample) != 2:
        raise ValueError("P33 unexpected P31 branch boundary")
    source = sample[0]
    anchors = (
        "const created = MonoTime.currTime;",
        "auto threads = new Thread[producers];",
        "foreach (t; threads)\n            launchOrAbort(t);",
        "foreach (t; threads)\n            joinOrAbort(t);",
        "const submitted = MonoTime.currTime;",
        "const stopped = MonoTime.currTime;",
        "const startBytes = GC.allocatedInCurrentThread();",
        "const endBytes = GC.allocatedInCurrentThread();",
        "if (work == P31Work.minimal)",
        "manager.publish(h, job)",
        "check(manager.orphan(h) && manager.joinOrphan(h) &&",
    )
    for anchor in anchors:
        if anchor not in source:
            # manager.publish belongs to the same branch but outside the
            # p31Measure function; both must remain independently visible.
            raise ValueError("P33 source contract drift: " + anchor)
    if source.index("const created = MonoTime.currTime;") > source.index(
            "auto threads = new Thread[producers];"):
        raise ValueError("P33 producer phase boundary drift")
    if not (source.index("launchOrAbort(t)") <
            source.index("joinOrAbort(t)") <
            source.index("const submitted = MonoTime.currTime;")):
        raise ValueError("P33 start/join order drift")
    print("P33_PINNED_P31_PHASE_CONTRACT_PASS")


def main():
    raw = (ROOT / REL).read_bytes()
    check_source(raw)


if __name__ == "__main__":
    main()
