#!/usr/bin/env bash
# Compiler contract probes only. No linking and no benchmark claim.
set -euo pipefail

DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCES="$ROOT/research/m1_task_lifetime/probes"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT

command -v "$DC" >/dev/null 2>&1 || {
    echo "compiler not found: $DC" >&2
    exit 2
}

echo "M1 lifetime compile probes: $DC"
"$DC" --version

# Same compile-only mode and preview flags on BOTH positive controls
# and expected failures. No linker failures can count as lifetime rejection.
compile_one() {
    local name="$1"
    "$DC" -c -preview=dip1000 "-of=$TEMP/$name.o" "$SOURCES/$name.d" \
        >"$TEMP/$name.log" 2>&1
}

for name in \
    positive_scope_local \
    positive_return_scope \
    positive_return_ref \
    positive_scope_delegate
do
    if ! compile_one "$name"; then
        echo "FAIL: positive control $name failed to compile" >&2
        cat -- "$TEMP/$name.log" >&2
        exit 1
    fi
    echo "PASS positive: $name"
done

for name in \
    negative_scope_return \
    negative_scope_global \
    negative_ref_escape \
    negative_stack_escape \
    negative_scope_delegate_escape
do
    if compile_one "$name"; then
        echo "FAIL: forbidden source $name unexpectedly compiled" >&2
        exit 1
    fi
    # Retain diagnostic text in the job log; do NOT assert a particular
    # wording, since errors vary between DMD and LDC.
    echo "PASS negative rejected: $name"
    cat -- "$TEMP/$name.log"
done

echo "PASS: 4 positive / 5 negative compile-only DIP1000 probes."
