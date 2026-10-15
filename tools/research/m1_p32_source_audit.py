#!/usr/bin/env python3
"""P32 preflight: immutable production source pins and narrowly scoped source anatomy.

This is not a concurrency safety proof and does not instrument or change production.
"""
import argparse
import hashlib
import subprocess
from pathlib import Path

PINS = {
    "source/concurrency/internal/owned_task.d":
        "e74d6a73f956c562eab176e27687a47249f5815d",
    "source/concurrency/internal/submission_pool.d":
        "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a",
}
EXPECTED = (
    "class TaskInbox",
    "SubmissionResult trySubmit(TaskRef task)",
    "bool hasCapacity()",
    "size_t takeBatch(scope TaskRef[] output)",
    "void completeOne()",
    "size_t wakeGeneration()",
    "void announceLocalWork()",
    "void parkUnlessChanged(size_t observed)",
    "void workerLoop(size_t self)",
    "const taken = _inbox.takeBatch(batch[]);",
    "_inbox.parkUnlessChanged(observed);",
    "synchronized (_mutex)",
)


def audit(root: Path):
    for relative, expected in PINS.items():
        path = root / relative
        if not path.is_file():
            raise ValueError(f"P32 missing pinned source: {relative}")
        # Git blobs hash b'blob <n>\\0' + raw bytes, not plain SHA1.
        data = path.read_bytes()
        blob = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
        actual = hashlib.sha1(blob).hexdigest()
        if actual != expected:
            raise ValueError(
                f"P32 production pin drift: {relative}: {actual} != {expected}"
            )
    source = (root / "source/concurrency/internal/submission_pool.d").read_text()
    for fragment in EXPECTED:
        if fragment not in source:
            raise ValueError(f"P32 source anatomy drift: {fragment}")
    print("P32_M0_SOURCE_PIN_AND_ANATOMY_PASS")


def self_test():
    payload = b"abc"
    record = b"blob 3\0" + payload
    if hashlib.sha1(record).hexdigest() != (
        "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f"
    ):
        raise ValueError("P32 git-blob hashing self-test failed")
    print("P32_AUDITOR_SELFTEST_PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    audit(args.root)


if __name__ == "__main__":
    main()
