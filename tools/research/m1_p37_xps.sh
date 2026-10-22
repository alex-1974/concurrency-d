#!/usr/bin/env bash
set -euo pipefail
DC="${P37_COMPILER:-ldc2}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
DIR="$BASE/concurrency/research"
P23="$DIR/m1_p23_owned.d"
POOL="$DIR/m1_p37_pool.d"
OWNER="$DIR/m1_p37_owned.d"
GEN="$BASE/consumer/p37_generational_owner.d"
OUT="${1:-$HOME/Downloads/concurrency-p37-xps-$(date -u +%Y%m%dT%H%M%SZ)}"
for path in "$P23" "$POOL" "$OWNER" "$GEN" "$OUT" "$OUT.tar.gz"; do
  [[ ! -e "$path" ]] || { echo "Refuse overwrite: $path" >&2; exit 2; }
done
command -v "$DC" >/dev/null
command -v dub >/dev/null
python3 "$ROOT/tools/research/m1_p37_source_audit.py"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cleanup() { rm -f -- "$P23" "$POOL" "$OWNER" "$GEN"; }
trap cleanup EXIT
python3 "$ROOT/tools/research/m1_p37_make_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
python3 "$ROOT/tools/research/m1_p37_make_owner.py" "$ROOT" "$P23" "$OWNER"
python3 "$ROOT/tools/research/m1_p37_make_consumer.py" "$ROOT" "$BASE/consumer/p29_generational_owner.d" "$GEN"
git -C "$ROOT" rev-parse HEAD > "$OUT/git-head.txt"
git -C "$ROOT" status --porcelain > "$OUT/git-status.txt"
"$DC" --version > "$OUT/compiler.txt" 2>&1
dub --version > "$OUT/dub.txt" 2>&1
lscpu > "$OUT/cpu.txt"
sha256sum "$POOL" "$OWNER" "$GEN" > "$OUT/generated-sha256.txt"
for session in 1 2 3; do
  case "$session" in
    1) arms=(original null timed);;
    2) arms=(null timed original);;
    3) arms=(timed original null);;
  esac
  for arm in "${arms[@]}"; do
    case "$arm" in
      original) config=p29-generational-optimized; marker=P31_FIXED_DIMENSIONS_BENCHMARK_PASS;;
      null) config=p37-null-optimized; marker=P37_INBOX_BENCHMARK_PASS;;
      timed) config=p37-timed-optimized; marker=P37_INBOX_BENCHMARK_PASS;;
    esac
    raw="$OUT/session$session-$arm.raw"
    timeout --signal=TERM --kill-after=5s 1200s dub run --root="$BASE" --compiler="$DC" --build=release --config="$config" --d-version=P31Benchmark -- --count 8192 --workers 4 --ingress 128 --retained 1024 --warmup 3 --rounds 9 > "$raw" 2>&1 || { cat "$raw" >&2; exit 1; }
    grep -Fx "$marker" "$raw" >/dev/null
    grep -E '^(phase,round,work|warmup,|measure,)' "$raw" > "$OUT/session$session-$arm.csv"
  done
  python3 "$ROOT/tools/research/m1_p31_analyze.py" --input "$OUT/session$session-original.csv" --min-rounds 9 --json "$OUT/session$session-original-summary.json" > "$OUT/session$session-original-validation.txt"
  python3 "$ROOT/tools/research/m1_p37_compare.py" "$OUT/session$session-null.csv" "$OUT/session$session-timed.csv" --min-rounds 9 > "$OUT/session$session-paired-validation.txt"
  python3 "$ROOT/tools/research/m1_p34_three_arm.py" "$OUT/session$session-original.csv" "$OUT/session$session-null.csv" "$OUT/session$session-timed.csv" --min-rounds 9 > "$OUT/session$session-three-arm.txt"
done
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
sha256sum "$OUT.tar.gz" > "$OUT.tar.gz.sha256"
echo "P37_XPS_ARCHIVE $OUT.tar.gz"
echo "P37_XPS_RECEIPT $OUT.tar.gz.sha256"
