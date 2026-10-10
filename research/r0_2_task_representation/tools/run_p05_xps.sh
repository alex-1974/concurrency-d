#!/usr/bin/env bash

main() {
    REPO="$(git rev-parse --show-toplevel 2>/dev/null)"

    if [ -z "$REPO" ]; then
        printf '%s\n' "ERROR: run this script from inside the concurrency-d repository" >&2
        return 1
    fi

    cd "$REPO" || return 1

    STAMP="$(date +%Y%m%d-%H%M%S)"
    OUT_DIR="research/r0_2_task_representation/evidence"
    mkdir -p "$OUT_DIR" || return 1

    SUMMARY="$OUT_DIR/xps-\${STAMP}-summary.txt"

    {
        echo "=== R0.2 P05 XPS QUALIFICATION ==="
        echo "timestamp=$STAMP"
        echo "commit=$(git rev-parse HEAD)"
        echo
        echo "=== PLATFORM ==="
        uname -a
        echo
        lscpu
        echo
        echo "=== TOOLCHAIN ==="
        ldc2 --version
        dub --version
        echo
    } | tee "$SUMMARY"

    RC=0

    run_probe() {
        NAME="$1"
        ROOT="$2"
        LOG="$OUT_DIR/xps-\${STAMP}-\${NAME}.log"

        echo "=== \${NAME} ===" | tee -a "$SUMMARY"

        dub run \
            --root="$ROOT" \
            --compiler=ldc2 \
            --build=release \
            --force \
            2>&1 | tee "$LOG"

        PROBE_RC=\${PIPESTATUS[0]}

        echo "rc=$PROBE_RC" | tee -a "$SUMMARY"
        echo "log=$LOG" | tee -a "$SUMMARY"
        echo | tee -a "$SUMMARY"

        if [ "$PROBE_RC" -ne 0 ]; then
            RC="$PROBE_RC"
        fi
    }

    run_probe \
        "p05a-flat" \
        "research/r0_2_task_representation/probes/p05a_taskref_flat"

    run_probe \
        "p05b-recursive" \
        "research/r0_2_task_representation/probes/p05b_taskref_recursive"

    run_probe \
        "p05c-irregular" \
        "research/r0_2_task_representation/probes/p05c_taskref_irregular"

    {
        echo "=== RESULT FILES ==="
        echo "$SUMMARY"
        echo "$OUT_DIR/xps-\${STAMP}-p05a-flat.log"
        echo "$OUT_DIR/xps-\${STAMP}-p05b-recursive.log"
        echo "$OUT_DIR/xps-\${STAMP}-p05c-irregular.log"
        echo
        echo "overall_rc=$RC"
    } | tee -a "$SUMMARY"

    return "$RC"
}

main "$@"
