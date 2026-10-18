#!/usr/bin/env python3
import argparse
import csv
import json
import re
from pathlib import Path
from datetime import datetime

def read(p):
    try:
        return p.read_text(encoding="utf-8").strip()
    except OSError:
        return ""

def timestamp(value):
    try:
        return datetime.fromisoformat(
            value.replace("Z", "+00:00")
        )
    except (ValueError, AttributeError):
        return None

def elapsed(a, b):
    x, y = timestamp(a), timestamp(b)
    return round((y-x).total_seconds(), 3) if x and y and y >= x else ""

def event_time(log, marker):
    for line in log.splitlines():
        if marker in line:
            m = re.search(
                r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d"
                r"(?:\.\d+)?(?:\+00:00|Z)",
                line
            )
            if m:
                return m.group(0)
    return ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="experiments/evaluation/openmrs")
    ap.add_argument("--output", default="analysis/results/openmrs")
    args = ap.parse_args()

    base = Path(args.base)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    rows = []

    logical = base/"scenario-c-d"/"logical-runs"

    for directory in sorted(logical.glob("run-*")):
        complete = (
            (directory/"COMPLETE").is_file()
            and not (directory/"INCOMPLETE").exists()
        )

        pilot_path = read(directory/"pilot-directory.txt")
        pilot = Path(pilot_path) if pilot_path else None

        controller = read(pilot/"controller.log") if pilot else ""
        reconciliation = read(directory/"reconciliation.log")

        authority = {}
        if pilot:
            try:
                authority = json.loads(
                    read(pilot/"controller-authority.json")
                )
            except (ValueError, OSError):
                pass

        decision = event_time(controller, "[DECISION]")
        fence_start = event_time(controller, "[FENCING]")
        fence_success = event_time(controller, "[FENCING VERIFIED]")
        placement = event_time(controller, "[PLACEMENT]")

        fenced = "[FENCING VERIFIED]" in controller
        recovery = "[RECOVERY VERIFIED]" in controller
        reconciled = "RECONCILIATION_VERIFIED" in reconciliation
        sql = "SQL_VERIFIED" in reconciliation

        rows.append({
            "run": directory.name,
            "complete_marker": complete,
            "pilot_directory": pilot_path,
            "original_node": authority.get("node", ""),
            "candidate_node": authority.get("candidate", ""),
            "decision_time": decision,
            "fence_start_time": fence_start,
            "fence_verified_time": fence_success,
            "placement_time": placement,
            "fencing_latency_seconds":
                elapsed(fence_start, fence_success),
            "fence_before_placement":
                bool(fenced and placement and
                     timestamp(fence_success) and
                     timestamp(placement) and
                     timestamp(fence_success) <= timestamp(placement)),
            "fencing_verified": fenced,
            "recovery_verified": recovery,
            "sql_verified": sql,
            "reconciliation_verified": reconciled,
            "post_fence_commit_count": "",
            "post_fence_commit_evidence": "NOT_MEASURED",
            "quality_status":
                "CHECKS_PASSED" if (
                    complete and fenced and recovery
                    and reconciled and sql
                ) else "REVIEW_REQUIRED"
        })

    columns = [
        "run", "complete_marker", "pilot_directory",
        "original_node", "candidate_node",
        "decision_time", "fence_start_time",
        "fence_verified_time", "placement_time",
        "fencing_latency_seconds", "fence_before_placement",
        "fencing_verified", "recovery_verified",
        "sql_verified", "reconciliation_verified",
        "post_fence_commit_count",
        "post_fence_commit_evidence", "quality_status"
    ]

    with (output/"fencing-metrics.csv").open(
        "w", newline="", encoding="utf-8"
    ) as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    print("C+D logical runs analyzed:", len(rows))
    print("Post-fence commit counts remain NOT_MEASURED.")

if __name__ == "__main__":
    main()