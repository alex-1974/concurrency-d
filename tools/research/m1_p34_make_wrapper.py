#!/usr/bin/env python3
"""P34: source-pinned research consumer generator."""
from pathlib import Path
import hashlib
import sys

PIN = "d19405f2ef0f8d7159978174c1a919ed6d66764f"


def main():
    source, destination = map(Path, sys.argv[1:3])
    raw = source.read_bytes()
    digest = hashlib.sha1(b"blob " + str(len(raw)).encode() + bytes([0]) + raw).hexdigest()
    if digest != PIN:
        raise ValueError("P34 consumer source drift: " + digest)
    text = raw.decode("utf-8")
    edits = [["module concurrency.research.p29_generational_owner;","module concurrency.research.p34_generational_owner;"],["        size_t producerBytes;\n    }\n\n    private bool p31Attempt","        size_t producerBytes;\n        ulong probeCalls;\n        ulong probeNs;\n    }\n\n    private bool p31Attempt"],["                    ++stats.attempts;\n                    if (work == P31Work.minimal)","                    ++stats.attempts;\n                    version (P34Timed)\n                        const beforeCall = MonoTime.currTime;\n                    if (work == P31Work.minimal)"],["                            manager, h, counted);\n                    if (!accepted)","                            manager, h, counted);\n                    version (P34Timed)\n                    {\n                        const afterCall = MonoTime.currTime;\n                        check(afterCall >= beforeCall, \"P34 clock reversed\");\n                        stats.probeNs += cast(ulong)\n                            (afterCall - beforeCall).total!\"nsecs\";\n                    }\n                    ++stats.probeCalls;\n                    if (!accepted)"],["        size_t attempts, acknowledged, producerBytes;\n        foreach (stat; stats)","        size_t attempts, acknowledged, producerBytes;\n        ulong probeCalls, probeNs;\n        foreach (stat; stats)"],["            producerBytes += stat.producerBytes;\n        }\n        ulong executed, checksum;","            producerBytes += stat.producerBytes;\n            probeCalls += stat.probeCalls;\n            probeNs += stat.probeNs;\n        }\n        check(probeCalls == attempts, \"P34 probe conservation\");\n        ulong executed, checksum;"],["            (stopped - begin).total!\"nsecs\");\n    }","            (stopped - begin).total!\"nsecs\", \",\",\n            probeCalls, \",\", probeNs);\n    }"],["            ~ \"join_release_ns,total_ns\");","            ~ \"join_release_ns,total_ns,probe_calls,probe_ns\");"],["writeln(\"P31_FIXED_DIMENSIONS_BENCHMARK_PASS\");","writeln(\"P34_WRAPPER_BENCHMARK_PASS\");"]]
    for old, new in edits:
        if text.count(old) != 1:
            raise ValueError("P34 source anchor drift: " + old[:70])
        text = text.replace(old, new, 1)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("// GENERATED P34 RESEARCH ONLY\n" + text)
    print("P34_SOURCE_PIN_PASS")


if __name__ == "__main__":
    main()
