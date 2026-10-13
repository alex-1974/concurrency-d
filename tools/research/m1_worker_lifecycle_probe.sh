#!/usr/bin/env bash
# P06: isolated druntime worker lifecycle checks; no public production code.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p04_value_only"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || exit 2

PREFIX="-version="
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    PREFIX="-d-version="
fi
"$DC" --version

for kind in M1P06Start M1P06Fatal; do
    "$DC" -unittest -main "${PREFIX}${kind}" -preview=dip1000 \
        "-I$ROOT/source" "-I$BASE" "-of=$TMP/$kind" \
        "$ROOT/source/concurrency/internal/task_record.d" \
        "$BASE/concurrency/research/m1_value_scope.d"
    # Fatal-worker probe runs in its own process; bounded even if druntime
    # aborts or deadlocks. It must exit normally for this research gate.
    timeout --signal=TERM --kill-after=2s 20s "$TMP/$kind"
    echo "P06 $kind: PASS"

    if [[ "$(basename -- "$DC")" == ldc2* ]]; then
        # Optimized correctness with assertions enabled: -release would
        # suppress the deliberately injected assertion-Error.
        "$DC" -O3 -unittest -main "${PREFIX}${kind}" -preview=dip1000 \
            "-I$ROOT/source" "-I$BASE" "-of=$TMP/$kind-optimized" \
            "$ROOT/source/concurrency/internal/task_record.d" \
            "$BASE/concurrency/research/m1_value_scope.d"
        timeout --signal=TERM --kill-after=2s 20s "$TMP/$kind-optimized"
        echo "P06 $kind LDC -O3 assertions-on: PASS"
    fi
done
