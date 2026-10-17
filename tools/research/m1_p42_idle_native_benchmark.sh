#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
OUT="${1:?usage: script NEW-OUTPUT-DIRECTORY}"
[[ ! -e "$OUT" ]] || { echo "refusing existing output directory: $OUT" >&2; exit 2; }
[[ ! -e "$POOL" ]] || { echo "refusing existing overlay: $POOL" >&2; exit 2; }
mkdir -p "$OUT/bin" "$OUT/raw"
OUT="$(cd "$OUT" && pwd)"
trap 'rm -f -- "$POOL"' EXIT
python3 "$ROOT/tools/research/m1_p42_make_conditional_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
git -C "$ROOT" rev-parse HEAD > "$OUT/commit.txt"
ldc2 --version > "$OUT/compiler.txt"
uname -a > "$OUT/platform.txt"
lscpu > "$OUT/cpu.txt"
sha256sum "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL" > "$OUT/sources.sha256"
for arm in baseline conditional; do
  echo "BUILD arm=$arm"
  dub build --root="$BASE" --compiler=ldc2 --build=release --config="p42-idle-$arm" > "$OUT/build-$arm.log" 2>&1
  cp "$BASE/m1-p11-real-pool" "$OUT/bin/$arm"
done
sha256sum "$OUT/bin/baseline" "$OUT/bin/conditional" > "$OUT/binaries.sha256"
printf 'session,pair,arm,round,publish_to_start_ticks\n' > "$OUT/results.csv"
for arm in baseline conditional; do
  for warmup in 1 2 3; do
    echo "WARMUP arm=$arm iteration=$warmup"
    timeout 120s "$OUT/bin/$arm" > /dev/null
  done
done
for session in 1 2 3; do
  for pair in 1 2 3 4 5 6; do
    if (( (session + pair) % 2 )); then arms=(conditional baseline); else arms=(baseline conditional); fi
    for arm in "${arms[@]}"; do
      echo "MEASURE session=$session pair=$pair arm=$arm"
      raw="$OUT/raw/s${session}-p${pair}-${arm}.txt"
      timeout 120s "$OUT/bin/$arm" > "$raw"
      grep -q "^P42_IDLE_PASS arm=$arm rounds=64 " "$raw"
      [[ "$(grep -c "^P42_IDLE_SAMPLE arm=$arm " "$raw")" == 64 ]]
      awk -v s="$session" -v p="$pair" -v a="$arm" '
        /^P42_IDLE_SAMPLE / {
          split($3, v, "=")
          split($4, t, "=")
          if (v[2] !~ /^[0-9]+$/ || t[2] !~ /^[0-9]+$/) exit 3
          print s "," p "," a "," v[2] "," t[2]
        }
      ' "$raw" >> "$OUT/results.csv"
    done
  done
done
sha256sum "$OUT/results.csv" > "$OUT/results.sha256"
echo "P42_IDLE_NATIVE_COMPLETE $OUT"
