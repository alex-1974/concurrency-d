#!/usr/bin/env python3
"""Opt-in Linux XPS thermal/frequency telemetry for P17 native run blocks.

Uses read-only Linux sysfs. Missing sensors remain unknown; do not silently
declare thermal stability. scaling_cur_freq is a sysfs report, not a calibrated
per-core instantaneous actual clock. Sampling may perturb the workload.
"""
import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path
import signal
import statistics
import sys
import time

STOP = False

def interrupt(_signum, _frame):
    global STOP
    STOP = True

def read_int(path):
    try:
        return int(Path(path).read_text().strip())
    except (FileNotFoundError, PermissionError, ValueError, OSError):
        return None

def discover_package_sensor(root=Path("/sys/class/hwmon")):
    try:
        hwmons=sorted(root.glob("hwmon*"))
    except OSError:
        return None
    for hwmon in hwmons:
        try:
            name=(hwmon/"name").read_text().strip()
        except OSError:
            continue
        if name not in ("coretemp", "k10temp"):
            continue
        for label in sorted(hwmon.glob("temp*_label")):
            try:
                title=label.read_text().strip()
            except OSError:
                continue
            if title in ("Package id 0", "Tctl", "Tdie"):
                stem=label.name[:-6]
                return (hwmon/(stem+"_input"), hwmon/(stem+"_max"),
                        hwmon/(stem+"_crit"))
    return None

def cpus_csv(text):
    values=[]
    for part in text.split(","):
        if "-" in part:
            a,b=part.split("-",1)
            values.extend(range(int(a),int(b)+1))
        else:
            values.append(int(part))
    if not values or any(v<0 for v in values) or len(set(values))!=len(values):
        raise ValueError("invalid CPU selection")
    return values

def sample(cpus,sensor):
    row={"utc":datetime.now(timezone.utc).isoformat(),
         "monotonic_ns":time.monotonic_ns()}
    for key in ("package_mC","temp_high_mC","temp_crit_mC"):
        row[key]=""
    if sensor:
        for key,path in zip(
            ("package_mC","temp_high_mC","temp_crit_mC"),sensor):
            value=read_int(path)
            row[key]="" if value is None else value
    for cpu in cpus:
        parent=Path(f"/sys/devices/system/cpu/cpu{cpu}")
        freq=read_int(parent/"cpufreq/scaling_cur_freq")
        row[f"cpu{cpu}_reported_khz"]="" if freq is None else freq
        thermal=read_int(parent/"thermal_throttle/package_throttle_count")
        row[f"cpu{cpu}_pkg_throttle_count"]="" if thermal is None else thermal
    return row

def cols(cpus):
    return ["utc","monotonic_ns","package_mC",
            "temp_high_mC","temp_crit_mC"] + [
                v for c in cpus
                for v in (f"cpu{c}_reported_khz",f"cpu{c}_pkg_throttle_count")
            ]

def assess(rows, cpus, limit):
    temperatures=[int(x["package_mC"])/1000 for x in rows
                  if x["package_mC"] not in ("",None)]
    frequencies=[int(x[f"cpu{c}_reported_khz"]) for x in rows for c in cpus
                 if x[f"cpu{c}_reported_khz"] not in ("",None)]
    deltas=[]
    for c in cpus:
        key=f"cpu{c}_pkg_throttle_count"
        values=[int(x[key]) for x in rows if x[key] not in ("",None)]
        if len(values)>1:
            deltas.append(max(0,values[-1]-values[0]))
    return {
        "samples":len(rows),
        "package_sample_count":len(temperatures),
        "max_package_c":max(temperatures) if temperatures else None,
        "median_package_c":statistics.median(temperatures) if temperatures else None,
        "minimum_reported_freq_khz":min(frequencies) if frequencies else None,
        "maximum_reported_freq_khz":max(frequencies) if frequencies else None,
        "throttle_count_delta_max":max(deltas) if deltas else None,
        "thermal_condition":"not_qualified" if (
            not temperatures or max(temperatures)>=limit or
            (deltas and max(deltas)>0)) else "screen_pass_not_proof",
    }

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--cpus",default="0,1,2,3")
    ap.add_argument("--output",type=Path)
    ap.add_argument("--interval",type=float,default=0.5)
    ap.add_argument("--max-package-c",type=float,default=95.0)
    ap.add_argument("--check",action="store_true")
    ap.add_argument("--self-test",action="store_true")
    a=ap.parse_args()
    if a.self_test:
        assert cpus_csv("0,1,4-5")==[0,1,4,5]
        assert assess([{"package_mC":100000,
                        "cpu0_reported_khz":"",
                        "cpu0_pkg_throttle_count":""}], [0],95)["thermal_condition"]=="not_qualified"
        print("P17 telemetry parser/self-test PASS")
        return
    cpus=cpus_csv(a.cpus)
    sensor=discover_package_sensor()
    if a.check:
        row=sample(cpus,sensor)
        temp=row["package_mC"]
        if temp=="":
            print("P17 package thermal sensor unavailable: NOT QUALIFIED",file=sys.stderr)
            raise SystemExit(3)
        value=int(temp)/1000
        print(f"P17 preflight package temperature: {value:.1f} C; "
              f"screening limit {a.max_package_c:.1f} C")
        if value>=a.max_package_c:
            print("P17 native speed qualification REFUSED: hot CPU. "
                  "Improve cooling and repeat, or explicitly use "
                  "P17_ALLOW_HOT=1 for diagnostic-only collection.",
                  file=sys.stderr)
            raise SystemExit(4)
        return
    if a.output is None or not 0.1<=a.interval<=10.0:
        ap.error("--output and 0.1 <= --interval <= 10 required")
    signal.signal(signal.SIGTERM,interrupt)
    signal.signal(signal.SIGINT,interrupt)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    with a.output.open("w",newline="") as f:
        writer=csv.DictWriter(f,fieldnames=cols(cpus))
        writer.writeheader()
        while not STOP:
            writer.writerow(sample(cpus,sensor))
            f.flush()
            time.sleep(a.interval)

if __name__=="__main__":
    main()
