#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path
from datetime import datetime

def read(p):
    try:
        return p.read_text(encoding="utf-8").strip()
    except OSError:
        return ""

def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None

def diff(a, b):
    x, y = ts(a), ts(b)
    return round((y-x).total_seconds(), 3) if x and y and y >= x else ""

def metadata(p):
    result = {}
    for line in read(p).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            result[k] = v
    return result

def analyze_run(directory, scenario, mode, run):
    m = metadata(directory/"metadata.env")
    original = m.get("original_pod", "")
    original_node = m.get("original_node", "")

    start = read(directory/"fault-time.txt") or read(
        directory/"fault-start-time.txt"
    )
    clear = read(directory/"fault-clear-time.txt")
    restored = read(directory/"clinical-restored-observed-time.txt")
    replacement_record = read(directory/"replacement-pod.txt")

    path = directory/"recovery-observations.csv"
    records = []

    if path.is_file():
        with path.open(newline="", encoding="utf-8") as f:
            records = list(csv.DictReader(f))

    original_seen = False
    replacement_seen = False
    replacement_ready_time = ""
    original_last_seen = ""

    for r in records:
        pod = r.get("pod", "")
        node = r.get("node", "")
        time = r.get("utc", "")
        ready = r.get("ready", "").lower() == "true"

        if pod == original and node == original_node:
            original_seen = True
            original_last_seen = time

        if (
            original and original_node
            and pod != original
            and node != original_node
            and pod and node
        ):
            replacement_seen = True
            if ready and not replacement_ready_time:
                replacement_ready_time = time

    return {
        "scenario": scenario,
        "mode": mode,
        "run": run,
        "original_pod": original,
        "original_node": original_node,
        "original_observed": original_seen,
        "original_last_seen": original_last_seen,
        "replacement_record": replacement_record,
        "replacement_observed": replacement_seen,
        "replacement_ready_time": replacement_ready_time,
        "fault_start": start,
        "fault_clear": clear,
        "fault_duration_seconds": diff(start, clear),
        "clinical_restored_time": restored,
        "fault_to_clinical_restoration_seconds": diff(start, restored),
        "fault_to_replacement_ready_seconds":
            diff(start, replacement_ready_time),
        "replacement_success_confirmed": bool(
            replacement_record and restored and replacement_seen
        ),
        "directory": str(directory)
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="experiments/evaluation/openmrs")
    ap.add_argument("--output", default="analysis/results/openmrs")
    args = ap.parse_args()

    base = Path(args.base)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    rows = []

    for scenario in ("scenario-b", "scenario-c"):
        for mode in ("V0", "T5", "T10", "T30", "FA1"):
            for directory in sorted((base/scenario/mode).glob("run-*")):
                if not (directory/"COMPLETE").is_file():
                    continue
                if (directory/"INCOMPLETE").exists():
                    continue

                rows.append(analyze_run(
                    directory, scenario, mode, directory.name
                ))

    columns = [
        "scenario", "mode", "run", "original_pod",
        "original_node", "original_observed", "original_last_seen",
        "replacement_record", "replacement_observed",
        "replacement_ready_time", "fault_start", "fault_clear",
        "fault_duration_seconds", "clinical_restored_time",
        "fault_to_clinical_restoration_seconds",
        "fault_to_replacement_ready_seconds",
        "replacement_success_confirmed", "directory"
    ]

    with (output/"recovery-metrics.csv").open(
        "w", newline="", encoding="utf-8"
    ) as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    print("Recovery runs analyzed:", len(rows))

if __name__ == "__main__":
    main()