#!/usr/bin/env bash
# P20 exact owned_task source-pinned native-M0 synthetic-pre-join fault.
# Does NOT inject a real pthread error or change production files.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
SOURCE="$ROOT/source/concurrency/internal/owned_task.d"
GENERATED="$BASE/concurrency/research/m1_p20_owned_fault.d"
TMP="$(mktemp -d)"
cleanup() {
    rm -f -- "$GENERATED"
    rm -rf -- "$TMP"
}
trap cleanup EXIT
if [[ -e "$GENERATED" ]]; then
    echo "FAIL P20: generated module already exists" >&2
    exit 1
fi
python3 "$ROOT/tools/research/m1_p20_make_owned_fault.py" \
    "$SOURCE" "$GENERATED"
"$DC" --version
for build in debug release; do
    timeout --signal=TERM --kill-after=5s 160s \
        dub run --root="$BASE" --compiler="$DC" \
            --build="$build" --config=owned-fault \
        >"$TMP/$build.log" 2>&1 || {
            cat "$TMP/$build.log" >&2
            exit 1
        }
    grep -Fx 'P20_OWNED_UNKNOWN_JOIN_PASS stopped_not_quiescent=1 real_join=1' \
        "$TMP/$build.log" >/dev/null || {
            cat "$TMP/$build.log" >&2
            echo "FAIL P20 $build: source-branch witness absent" >&2
            exit 1
        }
    echo "P20 owned synthetic early-stop / real native join $build: PASS"
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=5s 160s \
        dub run --root="$BASE" --compiler="$DC" \
            --build=debug --config=owned-fault-optimized \
        >"$TMP/optimized.log" 2>&1 || {
            cat "$TMP/optimized.log" >&2
            exit 1
        }
    grep -Fx 'P20_OWNED_UNKNOWN_JOIN_PASS stopped_not_quiescent=1 real_join=1' \
        "$TMP/optimized.log" >/dev/null || {
            cat "$TMP/optimized.log" >&2
            exit 1
        }
    echo "P20 LDC -O3 retained-checks: PASS"
fi
