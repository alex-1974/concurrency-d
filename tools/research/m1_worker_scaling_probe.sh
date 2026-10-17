#!/usr/bin/env bash
# P13: genuine M0 work-stealing same-pool wave scaling.
# CI checks semantic correctness, complete randomized matrix & checksums.
# NEVER gate on CI throughput or claim CI establishes XPS scaling.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
dub --version
bash -n "$ROOT/tools/research/m1_worker_scaling_xps.sh"

timeout --signal=TERM --kill-after=5s 120s \
    dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=smoke -- --profile smoke --count 256 --waves 2 \
        --warmup 1 --rounds 2 --seed 332922414 >"$TMP/smoke.raw"
grep -E '^(phase,round,|warmup,|measure,)' "$TMP/smoke.raw" >"$TMP/smoke.csv"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=5s 120s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config=optimized -- --profile smoke --count 256 --waves 3 \
            --warmup 1 --rounds 3 --seed 332922415 >"$TMP/optimized.raw"
    grep -E '^(phase,round,|warmup,|measure,)' "$TMP/optimized.raw" >"$TMP/optimized.csv"

    timeout --signal=TERM --kill-after=5s 120s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
            --config=release-mode -- --profile smoke --count 256 \
            --waves 3 --warmup 1 --rounds 3 \
            --seed 332922416 >"$TMP/release.raw"
    grep -E '^(phase,round,|warmup,|measure,)' "$TMP/release.raw" >"$TMP/release.csv"
fi

# Compiler and parser qualification of the FULL native experiment matrix,
# but with tiny bounded work — not a usable CI performance sample.
timeout --signal=TERM --kill-after=5s 120s \
    dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=smoke -- --profile native --count 64 --waves 2 \
        --warmup 0 --rounds 2 --seed 332922417 >"$TMP/native-matrix.raw"
grep -E '^(phase,round,|warmup,|measure,)' \
    "$TMP/native-matrix.raw" >"$TMP/native-matrix.csv"
python3 "$ROOT/tools/research/m1_worker_scaling_analyze.py" \
    --minimum-rounds 2 --require-profile native \
    "$TMP/native-matrix.csv"

python3 "$ROOT/tools/research/m1_worker_scaling_analyze.py" \
    --minimum-rounds 2 --require-profile smoke \
    "$TMP/smoke.csv" \
    $(if [[ "$(basename -- "$DC")" == ldc2* ]]; then \
        printf '%s ' "$TMP/optimized.csv" "$TMP/release.csv"; \
    fi)

echo "P13 real M0 multi-wave scaling CI gate PASS (NO speed threshold)"
