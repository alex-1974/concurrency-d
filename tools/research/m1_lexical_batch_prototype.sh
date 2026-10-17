#!/usr/bin/env bash
# M1 P02 lexical batch runtime research, not public package source.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || { echo "missing compiler: $DC" >&2; exit 2; }
"$DC" --version
"$DC" -preview=dip1000 "-I$ROOT/source" \
    "-of=$TMP/m1-p02-lexical-batch" \
    "$ROOT/source/concurrency/internal/task_record.d" \
    "$ROOT/research/m1_task_lifetime/prototypes/p02_lexical_batch/concurrency/research/m1_lexical_batch.d"
"$TMP/m1-p02-lexical-batch"

# Optimized LDC correctness gate. Leave runtime asserts enabled; -release
# would erase the very lifetime checks this research must execute.
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "-I$ROOT/source" \
        "-of=$TMP/m1-p02-lexical-batch-O3" \
        "$ROOT/source/concurrency/internal/task_record.d" \
        "$ROOT/research/m1_task_lifetime/prototypes/p02_lexical_batch/concurrency/research/m1_lexical_batch.d"
    "$TMP/m1-p02-lexical-batch-O3"
fi
