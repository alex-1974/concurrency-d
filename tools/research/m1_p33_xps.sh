#!/usr/bin/env bash
# P33 native XPS: unchanged P31 control vs generated P33 start-gate probe.
# Paired at profile/round level; altered scheduling is explicitly flagged.
set -euo pipefail
DC="${P33_COMPILER:-ldc2}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
OWNER="$BASE/concurrency/research/m1_p23_owned.d"
P33="$BASE/consumer/p33_generational_owner.d"
OUT="${1:-$HOME/Downloads/concurrency-p33-xps-$(date -u +%Y%m%dT%H%M%SZ)}"
[[ ! -e "$OUT" && ! -e "$OUT.tar.gz" && ! -e "$OWNER" && ! -e "$P33" ]] || {
  echo 'P33 refuses overwrite or stale generated input' >&2; exit 2;
}
command -v "$DC" >/dev/null
command -v dub >/dev/null
python3 "$ROOT/tools/research/m1_p33_source_audit.py"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cleanup() { rm -f -- "$OWNER" "$P33"; }
trap cleanup EXIT
python3 "$ROOT/tools/research/m1_p33_make_phase.py" \
  "$BASE/consumer/p29_generational_owner.d" "$P33"
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
  "$ROOT/source/concurrency/internal/owned_task.d" "$OWNER"
python3 - "$ROOT" "$P33" "$OUT/metadata.json" "$DC" <<'PY'
import datetime, hashlib, json, platform, subprocess, sys
from pathlib import Path
root, generated, output, dc = Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4]
def cmd(*args):
    try: return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT,timeout=15).strip()
    except Exception as ex: return "unavailable: "+str(ex)
def read(p):
    try: return Path(p).read_text().strip()
    except OSError: return "unavailable"
meta=dict(protocol="P33 unchanged-P31 versus start-gate generated-P31 paired research",
 started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
 git_head=cmd("git","-C",str(root),"rev-parse","HEAD"),
 git_status=cmd("git","-C",str(root),"status","--porcelain"),
 host=platform.node(),os=platform.platform(),cpu=cmd("lscpu"),
 compiler=cmd(dc,"--version"),dub=cmd("dub","--version"),
 p31_blob=cmd("git","-C",str(root),"hash-object",
  "research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d"),
 owner_blob=cmd("git","-C",str(root),"hash-object","source/concurrency/internal/owned_task.d"),
 pool_blob=cmd("git","-C",str(root),"hash-object","source/concurrency/internal/submission_pool.d"),
 generated_sha256=hashlib.sha256(generated.read_bytes()).hexdigest(),
 governor=read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
 frequency_start_khz=read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
 dimensions=dict(tasks=8192,workers=4,ingress=128,retained=1024,
 producers=[1,2,4],warmup=3,measured=9,sessions=3),
 limits="Start gate changes scheduling; no phase subtraction as causal estimate")
output.write_text(json.dumps(meta,indent=2,sort_keys=True)+"\n")
PY
for session in 1 2 3; do
  if (( session % 2 )); then arms=(control phases); else arms=(phases control); fi
  for arm in "${arms[@]}"; do
    if [[ "$arm" == control ]]; then
      config=p29-generational-optimized
      marker=P31_FIXED_DIMENSIONS_BENCHMARK_PASS
    else
      config=p33-phases-optimized
      marker=P33_PHASE_BENCHMARK_PASS
    fi
    raw="$OUT/session$session-$arm.raw"
    timeout --signal=TERM --kill-after=5s 1200s \
      dub run --root="$BASE" --compiler="$DC" --build=release \
      --config="$config" --d-version=P31Benchmark -- \
      --count 8192 --workers 4 --ingress 128 --retained 1024 \
      --warmup 3 --rounds 9 >"$raw" 2>&1 || { cat "$raw" >&2; exit 1; }
    grep -Fx "$marker" "$raw" >/dev/null
    grep -E '^(phase,round,work|warmup,|measure,)' "$raw" \
       >"$OUT/session$session-$arm.csv"
  done
  python3 "$ROOT/tools/research/m1_p31_analyze.py" \
    --input "$OUT/session$session-control.csv" --min-rounds 9 \
    --json "$OUT/session$session-control-summary.json" \
    >"$OUT/session$session-control-analysis.txt"
  python3 "$ROOT/tools/research/m1_p33_analyze.py" \
     "$OUT/session$session-phases.csv" --min-rounds 9 \
     >"$OUT/session$session-phases-analysis.txt"
  python3 "$ROOT/tools/research/m1_p33_compare.py" \
     "$OUT/session$session-control.csv" "$OUT/session$session-phases.csv" \
     --min-rounds 9 >"$OUT/session$session-paired-analysis.txt"
done
python3 - "$OUT/metadata.json" <<'PY'
import datetime,json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d["completed_utc"]=datetime.datetime.now(datetime.timezone.utc).isoformat()
f=Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
d["frequency_end_khz"]=f.read_text().strip() if f.exists() else "unavailable"
p.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
sha256sum "$OUT.tar.gz" >"$OUT.tar.gz.sha256"
echo "P33_XPS_ARCHIVE $OUT.tar.gz"
echo "P33_XPS_RECEIPT $OUT.tar.gz.sha256"
