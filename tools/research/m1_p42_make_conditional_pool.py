#!/usr/bin/env python3
"""Generate P42.6 conditional publish-notify research overlay from exact M0 source."""
from pathlib import Path
import sys

def once(s, a, z):
    if s.count(a)!=1: raise ValueError("P42.6 source anchor drift: "+a[:70])
    return s.replace(a,z,1)

def main():
    source,out=map(Path,sys.argv[1:3])
    s=source.read_text()
    s=once(s,"module concurrency.internal.submission_pool;",
           "module concurrency.research.m1_p42_pool;")
    s=once(s,"    private size_t _parkCount;",
           "    private size_t _parkCount;\n    private size_t _waiters;")
    old="""            ++_accepted;
            ++_generation;
            _changed.notify();
            return SubmissionResult.accepted;"""
    new="""            ++_accepted;
            ++_generation;
            // P42.6 research hypothesis only. Waiter count is protected by
            // the same mutex as publication and the wait predicate.
            if (_waiters != 0)
                _changed.notify();
            return SubmissionResult.accepted;"""
    s=once(s,old,new)
    old="""                ++_parkCount;
                _changed.wait();"""
    new="""                ++_parkCount;
                ++_waiters;
                _changed.wait();
                assert(_waiters != 0);
                --_waiters;"""
    s=once(s,old,new)
    anchor = """    size_t parkCount()\n    {\n        return _inbox.parkCount();\n    }"""
    replacement = anchor + """\n\n    // Research-only instantaneous count under the same inbox mutex.\n    size_t waiterCount()\n    {\n        return _inbox.waiterCount();\n    }"""
    s=once(s,anchor,replacement)
    inbox_anchor = """    size_t parkCount()\n    {\n        synchronized (_mutex)\n        {\n            return _parkCount;\n        }\n    }"""
    inbox_replacement = inbox_anchor + """\n\n    size_t waiterCount()\n    {\n        synchronized (_mutex)\n            return _waiters;\n    }"""
    s=once(s,inbox_anchor,inbox_replacement)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P42_CONDITIONAL_POOL_GENERATED research_only=true")
if __name__=="__main__":main()
