#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
OUT="${1:?usage: script NEW-OUTPUT-DIRECTORY}"
[[ ! -e "$OUT" && ! -e "$POOL" ]] || { echo "output or overlay already exists" >&2; exit 2; }
mkdir -p "$OUT/bin"
OUT="$(cd "$OUT" && pwd)"
trap 'rm -f -- "$POOL"' EXIT
python3 "$ROOT/tools/research/m1_p42_make_conditional_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
git -C "$ROOT" rev-parse HEAD > "$OUT/commit.txt"
ldc2 --version > "$OUT/compiler.txt"
sha256sum "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL" > "$OUT/sources.sha256"
for cost in light medium; do
  for arm in baseline conditional; do
    config="p42-bench-$arm"
    [[ "$cost" == medium ]] && config="$config-medium"
    dub build --root="$BASE" --compiler=ldc2 --build=release --config="$config" > "$OUT/build-$arm-$cost.log" 2>&1
    cp "$BASE/m1-p11-real-pool" "$OUT/bin/$arm-$cost"
  done
done
sha256sum "$OUT/bin/"* > "$OUT/binaries.sha256"
echo "cost,session,pair,arm,producers,workers,tasks,elapsed_us" > "$OUT/results.csv"
for cost in light medium; do
  for arm in baseline conditional; do
    for i in 1 2 3; do
      timeout 120s "$OUT/bin/$arm-$cost" 4 4 131072 > /dev/null
    done
  done
  for session in 1 2 3; do
    for pair in 1 2 3 4 5 6; do
      if (( (session + pair) % 2 )); then arms=(conditional baseline); else arms=(baseline conditional); fi
      for arm in "${arms[@]}"; do
        echo "MEASURE cost=$cost session=$session pair=$pair arm=$arm"
        line="$(timeout 120s "$OUT/bin/$arm-$cost" 4 4 131072)"
        [[ "$line" == P42_BENCH*elapsed_us=* ]] || exit 4
        value="${line##*elapsed_us=}"
        [[ "$value" =~ ^[0-9]+$ ]] || exit 4
        echo "$cost,$session,$pair,$arm,4,4,131072,$value" >> "$OUT/results.csv"
      done
    done
  done
done
sha256sum "$OUT/results.csv" > "$OUT/results.sha256"
echo "P42_TASK_COST_BENCHMARK_COMPLETE $OUT"
