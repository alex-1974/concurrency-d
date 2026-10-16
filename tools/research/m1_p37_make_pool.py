#!/usr/bin/env python3
"""Generate a research-only, source-pinned P37 inbox observation copy."""
from pathlib import Path
import hashlib
import sys

PIN="b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def once(text,old,new):
    if text.count(old)!=1:
        raise ValueError("P37 inbox anchor drift: "+old[:70])
    return text.replace(old,new,1)

def main():
    original,out=map(Path,sys.argv[1:3])
    raw=original.read_bytes()
    got=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
    if got!=PIN: raise ValueError("P37 inbox source pin drift: "+got)
    text=raw.decode()
    text=once(text,"module concurrency.internal.submission_pool;",
              "module concurrency.research.m1_p37_pool;")
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(text)
    print("P37_POOL_PIN_PASS")

if __name__=="__main__":
    main()
