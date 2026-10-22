#!/usr/bin/env bash
# P35 native three-arm ownership-path observations (no performance gate).
set -euo pipefail
DC="${P35_COMPILER:-ldc2}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
P23="$BASE/concurrency/research/m1_p23_owned.d"
OWNER="$BASE/concurrency/research/m1_p35_owned.d"
GEN="$BASE/consumer/p35_generational_owner.d"
OUT="${1:-$HOME/Downloads/concurrency-p35-xps-$(date -u +%Y%m%dT%H%M%SZ)}"
[[ ! -e "$OUT" && ! -e "$OUT.tar.gz" && ! -e "$P23" && ! -e "$OWNER" && ! -e "$GEN" ]] || {
  echo "P35 refuses overwrite or stale generated file" >&2; exit 2;
}
command -v "$DC" >/dev/null
command -v dub >/dev/null
python3 -m py_compile "$ROOT/tools/research/m1_p35_compare.py"
python3 "$ROOT/tools/research/m1_p35_source_audit.py"
mkdir -p -- "$OUT"
OUT="$(cd "$OUT" && pwd)"
cleanup() { rm -f -- "$P23" "$OWNER" "$GEN"; }
trap cleanup EXIT
python3 "$ROOT/tools/research/m1_p35_make_owner.py" "$ROOT" "$P23" "$OWNER"
python3 "$ROOT/tools/research/m1_p35_make_consumer.py" \
 "$BASE/consumer/p29_generational_owner.d" "$GEN"

python3 - "$ROOT" "$GEN" "$OUT/metadata.json" "$DC" <<'PY'
import datetime, hashlib, json, platform, subprocess, sys
from pathlib import Path
root, generated, output, compiler = Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4]
def call(*args):
    try:
        return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT,timeout=15).strip()
    except Exception as ex:
        return "unavailable: "+str(ex)
def read(p):
    try: return Path(p).read_text().strip()
    except OSError: return "unavailable"
meta=dict(
  protocol="P35 original P31 / generated null / generated timed matched ownership experiment",
  started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
  git_head=call("git","-C",str(root),"rev-parse","HEAD"),
  git_status=call("git","-C",str(root),"status","--porcelain"),
  host=platform.node(),os=platform.platform(),cpu=call("lscpu"),
  compiler=call(compiler,"--version"),dub=call("dub","--version"),
  owner_blob=call("git","-C",str(root),"hash-object","source/concurrency/internal/owned_task.d"),
  pool_blob=call("git","-C",str(root),"hash-object","source/concurrency/internal/submission_pool.d"),
  p31_blob=call("git","-C",str(root),"hash-object","research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d"),
  generated_sha256=hashlib.sha256(generated.read_bytes()).hexdigest(),
  generated_owner_sha256=hashlib.sha256((generated.parent.parent/"concurrency/research/m1_p35_owned.d").read_bytes()).hexdigest(),
  governor=read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
  frequency_start_khz=read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
  dimensions=dict(count=8192,workers=4,ingress=128,retained=1024,
      producers=[1,2,4],warmup=3,rounds=9,sessions=3),
  limits="TLS owner wait/hold timestamps perturb mutex contention; nested locks, manager scheduling, GC overlap; not original uncontended costs"
)
output.write_text(json.dumps(meta,indent=2,sort_keys=True)+"\n")
PY

for session in 1 2 3; do
  case "$session" in
    1) arms=(original null timed);;
    2) arms=(null timed original);;
    3) arms=(timed original null);;
  esac
  for arm in "${arms[@]}"; do
    case "$arm" in
      original) config=p29-generational-optimized; marker=P31_FIXED_DIMENSIONS_BENCHMARK_PASS;;
      null) config=p35-null-optimized; marker=P35_OWNER_MUTEX_BENCHMARK_PASS;;
      timed) config=p35-timed-optimized; marker=P35_OWNER_MUTEX_BENCHMARK_PASS;;
    esac
    raw="$OUT/session$session-$arm.raw"
    timeout --signal=TERM --kill-after=5s 1200s \
     dub run --root="$BASE" --compiler="$DC" --build=release \
       --config="$config" --d-version=P31Benchmark -- \
       --count 8192 --workers 4 --ingress 128 --retained 1024 \
       --warmup 3 --rounds 9 >"$raw" 2>&1 || {
         cat "$raw" >&2; exit 1;
       }
    grep -Fx "$marker" "$raw" >/dev/null
    grep -E '^(phase,round,work|warmup,|measure,)' "$raw" >"$OUT/session$session-$arm.csv"
  done
  python3 "$ROOT/tools/research/m1_p31_analyze.py" \
    --input "$OUT/session$session-original.csv" --min-rounds 9 \
    --json "$OUT/session$session-original-summary.json" >"$OUT/session$session-original-validation.txt"
  python3 "$ROOT/tools/research/m1_p35_compare.py" \
    "$OUT/session$session-null.csv" "$OUT/session$session-timed.csv" \
    --min-rounds 9 >"$OUT/session$session-null-timed-validation.txt"
  python3 "$ROOT/tools/research/m1_p34_three_arm.py" \
    "$OUT/session$session-original.csv" "$OUT/session$session-null.csv" \
    "$OUT/session$session-timed.csv" --min-rounds 9 \
    >"$OUT/session$session-three-arm.txt"
done
python3 - "$OUT/metadata.json" <<'PY'
import datetime,json,sys
from pathlib import Path
p=Path(sys.argv[1]);d=json.loads(p.read_text())
d["completed_utc"]=datetime.datetime.now(datetime.timezone.utc).isoformat()
f=Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
d["frequency_end_khz"]=f.read_text().strip() if f.exists() else "unavailable"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
sha256sum "$OUT.tar.gz" >"$OUT.tar.gz.sha256"
echo "P35_XPS_ARCHIVE $OUT.tar.gz"
echo "P35_XPS_RECEIPT $OUT.tar.gz.sha256"
