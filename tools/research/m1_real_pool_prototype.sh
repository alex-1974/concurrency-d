#!/usr/bin/env bash
# M1 P11: real M0 SubmissionWorkerPool + containers-d work stealing.
# Standalone DUB research consumer — no production source mutation.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
command -v "$DC" >/dev/null 2>&1
command -v dub >/dev/null 2>&1

"$DC" --version
dub --version

# Uses the real root concurrency-d package and its pinned containers-d 0.2.0
# dependency, not a local replacement deque or changed M0 source.
timeout --signal=TERM --kill-after=5s 160s \
    dub run --root="$BASE" --compiler="$DC" --build=debug

echo "P11 unchanged M0 submission pool DUB integration: PASS"
