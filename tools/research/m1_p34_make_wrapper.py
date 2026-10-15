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
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(raw)
    print("P34_SOURCE_PIN_PASS")


if __name__ == "__main__":
    main()
