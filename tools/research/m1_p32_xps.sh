#!/usr/bin/env bash
# P32-C: native matched untouched/pinned-timed M0 producer comparison.
# CI timings are diagnostics; run this on the XPS for native evidence.
set -euo pipefail
DC="${P32_COMPILER:-ldc2}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p32_admission_contention"
GEN="$ROOT/research/m1_task_lifetime/prototypes/p15_mutex_timing/generated/concurrency/research/m1_p15_pool.d"
OUT="${1:-$HOME/Downloads/concurrency-p32-xps-$(date -u +%Y%m%dT%H%M%SZ)}"
[[ ! -e "$OUT" && ! -e "$OUT.tar.gz" ]] || { echo 'Refusing to overwrite P32 evidence' >&2; exit 2; }
[[ ! -e "$GEN" ]] || { echo 'Stale generated P15 overlay' >&2; exit 2; }
command -v "$DC" >/dev/null
command -v dub >/dev/null
python3 "$ROOT/tools/research/m1_p32_source_audit.py" --self-test
python3 "$ROOT/tools/research/m1_p32_classify.py" --self-test
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cleanup() { rm -f -- "$GEN"; }
trap cleanup EXIT
python3 "$ROOT/tools/research/m1_p15_make_mutex_probe.py" \
 "$ROOT/source/concurrency/internal/submission_pool.d" "$GEN"
python3 - "$ROOT" "$OUT/metadata.json" "$DC" "$GEN" <<'PY'
import datetime, json, platform, subprocess, sys, hashlib
from pathlib import Path
root, dest, compiler, gen = Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],Path(sys.argv[4])
def run(*argv):
    try: return subprocess.check_output(argv, stderr=subprocess.STDOUT, text=True, timeout=15).strip()
    except Exception as ex: return 'unavailable: '+str(ex)
def read(path):
    try: return Path(path).read_text().strip()
    except OSError: return 'unavailable'
d=dict(protocol="P32 native same-task M0 control versus P15-timed pinned copy",
       started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
       host=platform.node(),os=platform.platform(),cpu=run("lscpu"),
       compiler=run(compiler,"--version"),dub=run("dub","--version"),
       git_head=run("git","-C",str(root),"rev-parse","HEAD"),
       git_status=run("git","-C",str(root),"status","--porcelain"),
       baseline_blob=run("git","-C",str(root),"hash-object","source/concurrency/internal/submission_pool.d"),
       owned_blob=run("git","-C",str(root),"hash-object","source/concurrency/internal/owned_task.d"),
       generated_sha256=hashlib.sha256(gen.read_bytes()).hexdigest(),
       governor=read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
       cpu0_frequency_start_khz=read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
       workload=dict(count=8192,workers=4,ingress=128,producers=[1,2,4]),
       warmup=3,rounds=9,build="DUB whole release -O3, assertions per release configuration",
       scope="Mechanism diagnostic only; M0 weaker than independent P29 lifetime contract")
dest.write_text(json.dumps(d,indent=2,sort_keys=True)+"\n")
PY

# Alternate process order to expose potential thermal/time drift.
# Every invocation covers all 1/2/4 profiles in rotating order.
for session in 1 2 3; do
    if (( session % 2 )); then variants=(control-optimized timed-optimized); else variants=(timed-optimized control-optimized); fi
    for variant in "${variants[@]}"; do
        raw="$OUT/session$session-$variant.raw"
        timeout --signal=TERM --kill-after=5s 1200s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$variant" -- --count 8192 --workers 4 \
            --ingress 128 --warmup 3 --rounds 9 >"$raw" 2>&1 || {
                cat "$raw" >&2; exit 1;
            }
        grep -Fx 'P32_M0_CONTROL_TIMED_PASS' "$raw" >/dev/null
        grep -E '^(phase,round,producers|warmup,|measure,)' "$raw" >"$OUT/session$session-$variant.csv"
    done
    python3 "$ROOT/tools/research/m1_p32_compare.py" \
       "$OUT/session$session-control-optimized.csv" \
       "$OUT/session$session-timed-optimized.csv" --min-rounds 9 \
       >"$OUT/session$session-analysis.txt"
done
python3 - "$OUT/metadata.json" <<'PY'
import datetime,json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
d["completed_utc"]=datetime.datetime.now(datetime.timezone.utc).isoformat()
f=Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
d["cpu0_frequency_end_khz"]=f.read_text().strip() if f.exists() else "unavailable"
p.write_text(json.dumps(d,sort_keys=True,indent=2)+"\n")
PY
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
sha256sum "$OUT.tar.gz" >"$OUT.tar.gz.sha256"
echo "P32_XPS_ARCHIVE $OUT.tar.gz"
echo "P32_XPS_RECEIPT $OUT.tar.gz.sha256"
echo 'P32 diagnostic only: instrumented wait/hold is perturbed; no automatic mechanism conclusion.'
