#!/usr/bin/env python3
import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

METRICS = {
    "run-metrics.csv": (
        "fault_duration_seconds",
        "clinical_success_pct"
    ),
    "clinical-metrics.csv": (
        "success_pct",
        "observed_outage_seconds",
        "longest_episode_seconds"
    ),
    "recovery-metrics.csv": (
        "fault_duration_seconds",
        "fault_to_clinical_restoration_seconds",
        "fault_to_replacement_ready_seconds"
    ),
    "fencing-metrics.csv": (
        "fencing_latency_seconds",
    )
}

def load(path):
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def numeric(value):
    try:
        return float(value)
    except (ValueError, TypeError):
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--input", default="analysis/results/openmrs"
    )
    args = ap.parse_args()

    directory = Path(args.input)
    groups = defaultdict(list)

    for filename, fields in METRICS.items():
        for row in load(directory/filename):
            if row.get("quality_status") == "REVIEW_REQUIRED":
                continue

            if filename == "clinical-metrics.csv" and (
                row.get("right_censored") == "True"
            ):
                excluded = {"observed_outage_seconds",
                            "longest_episode_seconds"}
            else:
                excluded = set()

            scenario = row.get("scenario", "scenario-c-d")
            profile = row.get("profile", "none")
            mode = row.get("mode", "FA1")

            for field in fields:
                if field in excluded:
                    continue

                value = numeric(row.get(field))
                if value is None:
                    continue

                groups[
                    (filename, scenario, profile, mode, field)
                ].append(value)

    results = []

    for key, values in sorted(groups.items()):
        results.append({
            "source": key[0],
            "scenario": key[1],
            "profile": key[2],
            "mode": key[3],
            "metric": key[4],
            "n": len(values),
            "mean": round(statistics.mean(values), 3),
            "median": round(statistics.median(values), 3),
            "sd": round(statistics.stdev(values), 3)
                  if len(values) > 1 else "",
            "minimum": round(min(values), 3),
            "maximum": round(max(values), 3)
        })

    columns = [
        "source", "scenario", "profile", "mode",
        "metric", "n", "mean", "median", "sd",
        "minimum", "maximum"
    ]

    output = directory/"grouped-summary.csv"

    with output.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(results)

    print("Grouped statistics:", len(results))
    print("Output:", output)

if __name__ == "__main__":
    main()