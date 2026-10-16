#!/usr/bin/env python3
"""Generate P35 consumer from immutable P31 source (research-only)."""
import hashlib
import sys
from pathlib import Path

PIN = "d19405f2ef0f8d7159978174c1a919ed6d66764f"

def replace_once(s, old, new):
    if s.count(old) != 1:
        raise ValueError("P35 consumer source drift: " + old[:70])
    return s.replace(old, new, 1)

def main():
    src, dst = map(Path, sys.argv[1:3])
    raw = src.read_bytes()
    actual = hashlib.sha1(b"blob " + str(len(raw)).encode() + bytes([0]) + raw).hexdigest()
    if actual != PIN:
        raise ValueError("P35 pinned consumer blob changed")
    s = raw.decode()
    s = replace_once(s, "module concurrency.research.p29_generational_owner;",
                     "module concurrency.research.p35_generational_owner;")
    s = replace_once(s, "import concurrency.research.m1_p23_owned : OwnedTaskExecutor;",
                     "import concurrency.research.m1_p35_owned : OwnedTaskExecutor, p35Take;")
    s = replace_once(s, "        size_t producerBytes;"+chr(10)+"    }",
                     "        size_t producerBytes;"+chr(10)+"        ulong p35Calls, p35WaitNs, p35HoldNs;"+chr(10)+"    }")
    s = replace_once(s, "            const endBytes = GC.allocatedInCurrentThread();",
                     "            auto observed = p35Take();"+chr(10)+
                     "            stats.p35Calls = observed.calls;"+chr(10)+
                     "            stats.p35WaitNs = observed.waitNs;"+chr(10)+
                     "            stats.p35HoldNs = observed.holdNs;"+chr(10)+
                     "            const endBytes = GC.allocatedInCurrentThread();")
    s = replace_once(s, "        size_t attempts, acknowledged, producerBytes;"+chr(10),
                     "        size_t attempts, acknowledged, producerBytes;"+chr(10)+
                     "        ulong p35Calls, p35WaitNs, p35HoldNs;"+chr(10))
    s = replace_once(s, "            producerBytes += stat.producerBytes;",
                     "            producerBytes += stat.producerBytes;"+chr(10)+
                     "            p35Calls += stat.p35Calls;"+chr(10)+
                     "            p35WaitNs += stat.p35WaitNs;"+chr(10)+
                     "            p35HoldNs += stat.p35HoldNs;")
    s = replace_once(s, "        ulong executed, checksum;",
                     "        check(p35Calls == (mode == P31Mode.m0 ? 0 : attempts),"+chr(10)+
                     "              \"P35 owner calls differ from attempts\");"+chr(10)+
                     "        ulong executed, checksum;")
    s = replace_once(s, "            (stopped - begin).total!\"nsecs\");",
                     "            (stopped - begin).total!\"nsecs\", \",\", "+chr(10)+
                     "            p35Calls, \",\", p35WaitNs, \",\", p35HoldNs);")
    s = replace_once(s, '            ~ "join_release_ns,total_ns");',
                     '            ~ "join_release_ns,total_ns,owner_calls,owner_wait_ns,owner_hold_ns");')
    s = replace_once(s, 'writeln("P31_FIXED_DIMENSIONS_BENCHMARK_PASS");',
                     'writeln("P35_OWNER_MUTEX_BENCHMARK_PASS");')
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(s)
    print("P35_CONSUMER_SOURCE_PIN_PASS")

if __name__ == "__main__":
    main()
