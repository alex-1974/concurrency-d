#!/usr/bin/env python3
"""Aggregate P17 per-process telemetry. Emits an evidence flag, not a pass gate.

A package temperature below 95 C in 500-ms samples cannot rule out
sub-sample transients or actual thermal throttling; sysfs scaling_cur_freq is
not the processor's actual per-worker execution frequency.
"""
import argparse
import csv
from pathlib import Path
from statistics import median

def analyze(folder,output):
    paths=sorted(folder.glob("session*-*.csv"))
    if not paths:
        raise ValueError("no P17 thermal time-series")
    fields=("file","samples","temperature_samples","min_temp_c","median_temp_c",
            "max_temp_c","min_reported_khz","max_reported_khz",
            "max_throttle_delta","qualification")
    report=[]
    for path in paths:
        with path.open(newline="") as f:
            data=list(csv.DictReader(f))
        if not data:
            raise ValueError(f"empty thermal trace: {path}")
        temps=[int(row["package_mC"])/1000 for row in data
               if row["package_mC"] not in ("",None)]
        freqkeys=[k for k in data[0] if k.endswith("_reported_khz")]
        freqs=[int(row[k]) for row in data for k in freqkeys
               if row[k] not in ("",None)]
        throttles=[]
        for k in data[0]:
            if not k.endswith("_pkg_throttle_count"):
                continue
            values=[int(row[k]) for row in data if row[k] not in ("",None)]
            if len(values)>=2:
                throttles.append(max(0,values[-1]-values[0]))
        status=("NOT_QUALIFIED" if
                not temps or max(temps)>=95 or
                (throttles and max(throttles)>0) else
                "SCREEN_ONLY_NOT_PROOF")
        report.append({
            "file":path.name,
            "samples":len(data),
            "temperature_samples":len(temps),
            "min_temp_c":min(temps) if temps else "",
            "median_temp_c":median(temps) if temps else "",
            "max_temp_c":max(temps) if temps else "",
            "min_reported_khz":min(freqs) if freqs else "",
            "max_reported_khz":max(freqs) if freqs else "",
            "max_throttle_delta":max(throttles) if throttles else "",
            "qualification":status,
        })
    with output.open("w",newline="") as f:
        writer=csv.DictWriter(f,fieldnames=fields)
        writer.writeheader()
        writer.writerows(report)
    good=sum(item["qualification"]=="SCREEN_ONLY_NOT_PROOF" for item in report)
    print(f"P17 sampled-thermal screening: {good}/{len(report)} process traces "
          "below 95 C with no observed throttle-counter increment")
    if good!=len(report):
        print("P17 PERFORMANCE NOT QUALIFIED — hot/missing sensors or "
              "observed throttle counter increments.")
    else:
        print("P17 THERMAL SCREEN ONLY — frequencies and thermal limits "
              "still require independent qualification.")
    print("No run has a continuously pinned per-worker frequency trace.")

def main():
    p=argparse.ArgumentParser()
    p.add_argument("telemetry_directory",type=Path)
    p.add_argument("output",type=Path)
    a=p.parse_args()
    analyze(a.telemetry_directory,a.output)

if __name__=="__main__":
    main()
