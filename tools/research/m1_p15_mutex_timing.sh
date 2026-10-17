#!/usr/bin/env bash
# P15: exact reviewed M0 source, identical P13 workload with/without
# invasive clock reads around 5 specified TaskInbox mutex paths.
# No CI speed threshold, no claim of uninstrumented wait/hold costs.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p15_mutex_timing"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
dub --version
python3 "$ROOT/tools/research/m1_p15_make_mutex_probe.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p15_pool.d"
python3 "$ROOT/tools/research/m1_p15_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"
bash -n "$ROOT/tools/research/m1_p15_xps.sh"

p15_run() {
    local config="$1" profile="$2" count="$3" waves="$4"
    local rounds="$5" build="$6" seed="$7" label="$8"
    timeout --signal=TERM --kill-after=5s 170s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
            --config="$config" -- --profile "$profile" \
            --count "$count" --waves "$waves" \
            --warmup 1 --rounds "$rounds" --seed "$seed" \
            >"$TMP/$label.raw"
    grep -E '^(phase,round,|warmup,|measure,)' "$TMP/$label.raw" >"$TMP/$label.csv"
}

p15_run control smoke 128 2 2 debug 332922710 control-debug
p15_run timed smoke 128 2 2 debug 332922710 timed-debug
python3 "$ROOT/tools/research/m1_p15_compare.py" \
    "$TMP/control-debug.csv" "$TMP/timed-debug.csv"

# Entire target scenario matrix is checked on both compilers with bounded
# small task counts. The sampled CI durations are purely diagnostic.
p15_run control native 32 2 2 debug 332922711 control-native
p15_run timed native 32 2 2 debug 332922711 timed-native
python3 "$ROOT/tools/research/m1_p15_compare.py" \
    "$TMP/control-native.csv" "$TMP/timed-native.csv" --min-rows 90

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    p15_run control-optimized smoke 128 3 3 debug 332922712 control-O3
    p15_run timed-optimized smoke 128 3 3 debug 332922712 timed-O3
    python3 "$ROOT/tools/research/m1_p15_compare.py" \
        "$TMP/control-O3.csv" "$TMP/timed-O3.csv"

    # Source oracle/checks are explicit and survive release.
    p15_run control smoke 128 3 3 release 332922713 control-release
    p15_run timed smoke 128 3 3 release 332922713 timed-release
    python3 "$ROOT/tools/research/m1_p15_compare.py" \
        "$TMP/control-release.csv" "$TMP/timed-release.csv"
fi

echo "P15 pinned-source M0 lock-timing research qualification PASS"
