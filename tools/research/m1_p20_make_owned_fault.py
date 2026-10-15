#!/usr/bin/env python3
"""P20: source-pinned research-only fault seam in actual M0 owned executor.

The generated module runs the original M0 scheduler and task records.
ONLY the owned-layer module name, explicit synthetic shutdown fault hook,
and a test-only post-fault native join/reap method differ.
"""
from __future__ import annotations

import hashlib
from pathlib import Path
import sys

EXPECTED_BLOB = "e74d6a73f956c562eab176e27687a47249f5815d"


def swap_once(data: str, old: str, new: str, title: str) -> str:
    if data.count(old) != 1:
        raise SystemExit(f"P20 SOURCE PIN/ANCHOR mismatch ({title}): {data.count(old)}")
    return data.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: m1_p20_make_owned_fault.py M0_OWNED_TASK SOURCE_OUTPUT")
    source_path, target_path = map(Path, sys.argv[1:])
    raw = source_path.read_bytes()
    blob = hashlib.sha1(
        b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw
    ).hexdigest()
    if blob != EXPECTED_BLOB:
        raise SystemExit(f"P20 M0 source drift: {blob} != {EXPECTED_BLOB}")

    src = raw.decode("utf-8")
    src = swap_once(
        src, "module concurrency.internal.owned_task;",
        "module concurrency.research.m1_p20_owned_fault;",
        "module identity",
    )
    src = swap_once(
        src, "import std.traits :\n    ReturnType;",
        "import std.traits :\n    ReturnType;\n"
        "import core.stdc.stdlib : abort;",
        "fail-stop import",
    )
    src = swap_once(
        src, "    private Throwable _shutdownFailure;",
        """    private Throwable _shutdownFailure;

    // P20 ONLY: not a production API or recoverable native-join policy.
    private bool _researchInjectBeforeJoin;

    void researchInjectBeforeJoin() @system
    {
        _researchInjectBeforeJoin = true;
    }

    // P20 ONLY: testing a path with NO real failed native operation.
    // This explicit successful real native join proves quiescence before
    // the research harness releases any owned roots. A native join error
    // cannot be treated as an ordinary recoverable return here.
    void researchProveJoinAfterInjectedFault() @system
    {
        if (!_researchInjectBeforeJoin || _shutdownFailure is null)
            throw new Exception("P20 recover without expected injection");
        try
            _pool.closeAndJoin();
        catch (Throwable)
            abort();

        synchronized (_mutex)
        {
            foreach (ref entry; _retained)
                entry = RetainedTask.init;
            _retained.length = 0;
            _shutdownFailure = null;
            _lifecycle = Lifecycle.stopped;
            _lifecycleChanged.notifyAll();
        }
    }""",
        "test-only recovery hook",
    )
    src = swap_once(
        src,
        "        try\n        {\n            _pool.closeAndJoin();\n"
        "        }\n        catch (Throwable error)",
        """        try
        {
            if (_researchInjectBeforeJoin)
                throw new Exception("P20 synthetic pre-join fault");
            _pool.closeAndJoin();
        }
        catch (Throwable error)""",
        "original close path injection",
    )
    dest = target_path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(src)
    print("P20_SOURCE_PIN_PASS " + blob)


if __name__ == "__main__":
    main()
