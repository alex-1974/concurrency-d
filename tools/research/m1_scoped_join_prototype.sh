#!/usr/bin/env bash
# Standalone M1 P01 bounded-scope research prototype (NOT a package API).
set -euo pipefail

DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || { echo "missing compiler: $DC" >&2; exit 2; }

"$DC" --version
"$DC" -preview=dip1000 "-I$ROOT/source" \
    "-of=$TMP/m1-p01-scoped-join" \
    "$ROOT/source/concurrency/internal/task_record.d" \
    "$ROOT/research/m1_task_lifetime/prototypes/p01_scoped_join/concurrency/research/m1_scoped_join.d"
"$TMP/m1-p01-scoped-join"
