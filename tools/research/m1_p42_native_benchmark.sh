#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
OUT="${1:?usage: script NEW-OUTPUT-DIRECTORY}"
[[ ! -e "$OUT" ]] || { echo "refusing existing output: $OUT" >&2; exit 2; }
[[ ! -e "$POOL" ]] || { echo "refusing existing overlay: $POOL" >&2; exit 2; }
mkdir -p "$OUT/bin"
OUT="$(cd "$OUT" && pwd)"
trap 'rm -f -- "$POOL"' EXIT
python3 "$ROOT/tools/research/m1_p42_make_conditional_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
sha256sum "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL" > "$OUT/sources.sha256"
git -C "$ROOT" rev-parse HEAD > "$OUT/commit.txt"
ldc2 --version > "$OUT/toolchain.txt"
uname -a > "$OUT/platform.txt"
date -Is > "$OUT/start-time.txt"
lscpu > "$OUT/cpu.txt"
for arm in baseline conditional; do
  echo "BUILD $arm"
  dub build --root="$BASE" --compiler=ldc2 --build=release --config="p42-bench-$arm" > "$OUT/build-$arm.log" 2>&1
  EXE="$BASE/m1-p11-real-pool"
  [[ -x "$EXE" ]] || { echo "built executable not found: $EXE" >&2; exit 3; }
  cp "$EXE" "$OUT/bin/$arm"
done
sha256sum "$OUT/bin/baseline" "$OUT/bin/conditional" > "$OUT/binaries.sha256"
printf 'session,position,arm,producers,workers,tasks,elapsed_us\n' > "$OUT/results.csv"
for config in 1:1 2:2 4:4; do
  IFS=: read -r producers workers <<< "$config"
  for arm in baseline conditional; do
    echo "WARMUP config=$config arm=$arm"
    for warmup in 1 2 3; do
      timeout 120s "$OUT/bin/$arm" "$producers" "$workers" 131072 >/dev/null
    done
  done
done
for session in 1 2 3 4 5 6; do
  for config in 1:1 2:2 4:4; do
    IFS=: read -r producers workers <<< "$config"
    for position in 1 2 3 4; do
      if (( (session + position) % 2 )); then arms=(conditional baseline); else arms=(baseline conditional); fi
      for arm in "${arms[@]}"; do
        echo "MEASURE session=$session config=$config position=$position arm=$arm"
        line="$(timeout 120s "$OUT/bin/$arm" "$producers" "$workers" 131072)"
        [[ "$line" == P42_BENCH*elapsed_us=* ]] || { echo "invalid output: $line" >&2; exit 4; }
        value="${line##*elapsed_us=}"
        [[ "$value" =~ ^[0-9]+$ ]] || { echo "invalid elapsed time: $value" >&2; exit 4; }
        printf '%s,%s,%s,%s,%s,%s,%s\n' "$session" "$position" "$arm" "$producers" "$workers" 131072 "$value" >> "$OUT/results.csv"
      done
    done
  done
done
date -Is > "$OUT/end-time.txt"
sha256sum "$OUT/results.csv" > "$OUT/results.sha256"
echo "P42_NATIVE_BENCHMARK_COMPLETE $OUT"
