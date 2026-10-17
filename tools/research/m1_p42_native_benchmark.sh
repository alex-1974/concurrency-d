#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
OUT="${1:?provide output directory}"
mkdir -p "$OUT"
test ! -e "$POOL"
trap 'rm -f "$POOL"' EXIT
python3 "$ROOT/tools/research/m1_p42_make_conditional_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
sha256sum "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL" > "$OUT/sources.sha256"
git rev-parse HEAD > "$OUT/commit.txt"
ldc2 --version > "$OUT/toolchain.txt"
echo "session,position,arm,producers,workers,tasks,elapsed_us" > "$OUT/results.csv"
for session in 1 2 3; do
  for config in 1:1 2:2 4:4; do
    IFS=: read -r producers workers <<< "$config"
    for position in 1 2 3 4; do
      if (( (session + position) % 2 )); then
        arms=(conditional baseline)
      else
        arms=(baseline conditional)
      fi
      for arm in "${arms[@]}"; do
        line="$(timeout 120s dub run --root="$BASE" --compiler=ldc2 --build=release --config="p42-bench-$arm" -- "$producers" "$workers" 8192 | grep P42_BENCH)"
        value="${line##*elapsed_us=}"
        echo "$session,$position,$arm,$producers,$workers,8192,$value" >> "$OUT/results.csv"
      done
    done
  done
done
sha256sum "$OUT/results.csv" > "$OUT/results.sha256"
