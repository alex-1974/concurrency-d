#!/usr/bin/env bash
# P18 research-only native producer cadence intervention.
# Three intentionally different producer workloads; M0/P18 compared only
# WITHIN cadence+CPU mask. Do not infer speed across different cadences.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-cadence-$(date +%Y%m%d-%H%M%S)}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
TMP=""
MONITOR=""
cleanup() {
  if [[ -n "$MONITOR" ]]; then kill "$MONITOR" 2>/dev/null || :; wait "$MONITOR" 2>/dev/null || :; fi
  if [[ -n "$TMP" ]]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT
[[ "${P18_CADENCE_SESSIONS:-6}" == 6 ]] || { echo "exactly six sessions required" >&2; exit 2; }
[[ ! -e "$DEST" && ! -e "$DEST.tar.gz" ]] || { echo "P18 refusing overwrite" >&2; exit 2; }
for x in "$DC" dub taskset python3 timeout tar sha256sum git cmp; do
  command -v "$x" >/dev/null || { echo "missing $x" >&2; exit 2; }
done
M0="$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
[[ "$M0" == b7d8fafcb3179f00cba7e89e28c6d6b9b676353a ]] || { echo "M0 source drift" >&2; exit 3; }
declare -A core_ids=()
for cpu in 0 1 2 3; do
  taskset -c "$cpu" true
  cp="/sys/devices/system/cpu/cpu$cpu/topology"
  [[ -r "$cp/core_id" && -r "$cp/physical_package_id" ]] || exit 3
  key="$(cat "$cp/physical_package_id"):$(cat "$cp/core_id")"
  [[ ! -v "core_ids[$key]" ]] || { echo "SMT sibling CPU" >&2; exit 3; }
  core_ids["$key"]=1
done
for cpus in 0 0,1,2,3; do
  taskset -c "$cpus" python3 - "$cpus" <<'PY'
import os,sys
expect={int(x) for x in sys.argv[1].split(",")}
if os.sched_getaffinity(0)!=expect:raise SystemExit("cpuset narrowed")
PY
done
mkdir -p "$DEST"/{raw,csv,diagnostics,telemetry}
DEST="$(cd "$DEST" && pwd)"
python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
  "$ROOT/source/concurrency/internal/submission_pool.d" \
  "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
  "$P13/concurrency/research/m1_scaling_kernel.d" \
  "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"
python3 "$ROOT/tools/research/m1_p18_cadence_make_fixture.py" \
  "$P13/concurrency/research/m1_scaling_kernel.d" \
  "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"
TMP="$(mktemp -d)"
for cadence in cadence0 cadence8 cadence64; do
  for arm in control grace; do
    mode="$cadence-$arm"
    dub build --root="$BASE" --compiler="$DC" --build=release --config="$mode"
    cp "$BASE/m1-p18-idle-grace" "$TMP/$mode"
    sha256sum "$TMP/$mode" >>"$DEST/diagnostics/binary-sha256.txt"
  done
  cmp -s "$TMP/$cadence-control" "$TMP/$cadence-grace" && {
    echo "identical M0/P18 binary" >&2; exit 3;
  }
done
for arm in control grace; do
  for cadence in cadence8 cadence64; do
    cmp -s "$TMP/cadence0-$arm" "$TMP/$cadence-$arm" && {
      echo "cadence variant binary identical to 0" >&2; exit 3;
    }
  done
done
for mask in 0 0,1,2,3; do
  if [[ "$mask" == 0 ]]; then name=cpu1; else name=cpu4; fi
  for mode in race-control race-grace; do
    taskset -c "$mask" timeout --signal=TERM --kill-after=5s 150s \
      dub run --root="$BASE" --compiler="$DC" --build=release --config="$mode" -- 12 \
      >"$DEST/diagnostics/$name-$mode.log" 2>&1
    grep -q 'PASS' "$DEST/diagnostics/$name-$mode.log"
  done
done
{
  echo 'study=intentionally different producer cadence 0,8,64 success yields'
  echo "source_head=$(git -C "$ROOT" rev-parse HEAD)"
  echo "M0_source_blob=$M0"
  echo "compiler=$(command -v "$DC")"
  "$DC" --version
  dub --version
  uname -a
  echo 'worker=1; iterations=128,512,1024; ingress=8,2048'
  echo 'tasks_per_wave=2048; waves=3; warmup=2; measured_rounds=5'
  echo 'cadence_success_yields_per_case=0,765,93'
  echo 'sessions=6; masks=cpu1:0,cpu4:0,1,2,3; ABBA/BAAB'
  echo 'six_session_pattern_permutations=all_6'
  echo 'cross_cadence_speed_not_semantically_same_workload=true'
  echo 'within_cadence_M0_P18_uninstrumented=true'
  echo 'historical_unmodified_affinity_archive_SHA256=5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1'
  if command -v lscpu >/dev/null; then lscpu; fi
} >"$DEST/manifest.txt"
for session in 1 2 3 4 5 6; do
  seed="$((332925000 + session*101))"
  if ((session%2 == 1)); then
    masks=(1 4); arms=(control grace grace control)
  else
    masks=(4 1); arms=(grace control control grace)
  fi
  case "$session" in
    1) patterns=(cadence0 cadence8 cadence64) ;;
    2) patterns=(cadence64 cadence8 cadence0) ;;
    3) patterns=(cadence8 cadence64 cadence0) ;;
    4) patterns=(cadence0 cadence64 cadence8) ;;
    5) patterns=(cadence64 cadence0 cadence8) ;;
    6) patterns=(cadence8 cadence0 cadence64) ;;
  esac
  echo "${masks[*]}" >"$DEST/diagnostics/session$session-mask-order.txt"
  echo "${patterns[*]}" >"$DEST/diagnostics/session$session-pattern-order.txt"
  echo "${arms[*]}" >"$DEST/diagnostics/session$session-arm-order.txt"
  for cpu in "${masks[@]}"; do
    if [[ "$cpu" == 1 ]]; then cpus=0; else cpus=0,1,2,3; fi
    for cadence in "${patterns[@]}"; do
      nc=0; ng=0
      for arm in "${arms[@]}"; do
        if [[ "$arm" == control ]]; then nc=$((nc+1)); half="$nc"
        else ng=$((ng+1)); half="$ng"; fi
        label="session$session-cpu$cpu-$cadence-$arm$half"
        echo "P18 cadence run $label" >&2
        python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" \
          snapshot --cpus "$cpus" --mode observe \
          >>"$DEST/diagnostics/thermal-snapshots.txt"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
          --cpus "$cpus" --interval 0.5 \
          --output "$DEST/telemetry/$label.csv" &
        MONITOR=$!
        if taskset -c "$cpus" timeout --signal=TERM --kill-after=5s 300s \
          "$TMP/$cadence-$arm" --profile cadencefocus --count 2048 \
          --waves 3 --warmup 2 --rounds 5 --seed "$seed" \
          >"$DEST/raw/$label.log" 2>&1; then
          kill "$MONITOR" 2>/dev/null || :; wait "$MONITOR" 2>/dev/null || :
          MONITOR=""
        else
          rc=$?; echo "P18 cadence failed $label ($rc)" >&2; exit "$rc"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' \
          "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"
        [[ "$(wc -l <"$DEST/csv/$label.csv")" -eq 43 &&
           "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -eq 12 &&
           "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -eq 30 ]] ||
          { echo "incomplete case rows $label" >&2; exit 4; }
      done
    done
  done
done
python3 "$ROOT/tools/research/m1_p18_cadence_compare.py" "$DEST/csv" \
  --sessions 6 --warmup 2 --rounds 5 --count 2048 --waves 3 \
  >"$DEST/diagnostics/paired-cadence-review.txt"
python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" review \
  "$DEST/telemetry" "$DEST/thermal-summary.csv" >"$DEST/thermal-review.txt"
tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 producer cadence source-pinned native archive: $DEST.tar.gz"
echo 'CAUTION: different cadences are intentionally different producer workloads.'
