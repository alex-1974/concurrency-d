#!/usr/bin/env python3
"""Generate P16.2 exactly matched P13 original-M0 / atomic-completion arms.

The TaskRefs, kernel, worker pool construction, waves, oracle, producer
backpressure, and native joins are identical; ONLY imported pool differs.
"""
import argparse
import hashlib
from pathlib import Path

KERNEL_BLOB = "3852e8788757b62c5000ad55565359d6a20a78c1"
DRIVER_BLOB = "723de6bf76ac838b10de4b3f1cb901315a5ced38"

def checked(path, expected):
    raw = path.read_bytes()
    sha = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if sha != expected:
        raise RuntimeError(f"P16.2 source drift in {path}: {sha}")
    return raw.decode("utf8")

def once(text, source, replacement):
    n = text.count(source)
    if n != 1:
        raise RuntimeError(f"P16.2 bad fixture source anchor ({n}): {source[:110]!r}")
    return text.replace(source, replacement, 1)

def generate(kernel, driver, dest):
    code = checked(kernel, KERNEL_BLOB)
    main = checked(driver, DRIVER_BLOB)
    code = once(code,
        "module concurrency.research.m1_scaling_kernel;",
        "module concurrency.research.m1_p16_2_kernel;")
    code = once(code,
        """import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;""",
        """version (P162Atomic)
{
    import concurrency.research.m1_p16_2_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}""")
    main = once(main,
        "module concurrency.research.p13_consumer;",
        "module concurrency.research.p16_2_consumer;")
    main = once(main,
        "import concurrency.research.m1_scaling_kernel :",
        "import concurrency.research.m1_p16_2_kernel :")
    main = once(main,
        'stderr.writeln("P13 CI measurements are DIAGNOSTIC ONLY; ",',
        'stderr.writeln("P16.2 atomic completion RESEARCH, semantics first; ",')
    for name, contents in [
        ("concurrency/research/m1_p16_2_kernel.d", code),
        ("consumer/main.d", main),
    ]:
        path = dest / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "// P16.2 generated from EXACT P13 Git blobs; do not edit.\n"
            + contents, encoding="utf-8")
        print("P16.2 same-task source generated:", path)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("kernel", type=Path)
    ap.add_argument("driver", type=Path)
    ap.add_argument("destination", type=Path)
    a = ap.parse_args()
    generate(a.kernel, a.driver, a.destination)
