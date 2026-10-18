#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path
from datetime import datetime, timezone

MODES = ("V0", "T5", "T10", "T30", "FA1")
PROFILES = ("mild", "moderate", "severe")

def read(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""

def stamp(value):
    try:
        return datetime.fromisoformat(
            value.replace("Z", "+00:00")
        ) if value else None
    except ValueError:
        return None

def seconds(a, b):
    x, y = stamp(a), stamp(b)
    return round((y-x).total_seconds(), 3) if x and y and y >= x else ""

def write_csv(path, rows, columns):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

def status(p):
    if not p.exists():
        return "MISSING"
    if (p/"COMPLETE").is_file() and not (p/"INCOMPLETE").exists():
        return "COMPLETE"
    return "INCOMPLETE"

def planned(base):
    for scenario, ids in (
        ("scenario-b", (3, 4, 5)),
        ("scenario-c", (3, 4))
    ):
        for mode in MODES:
            for i in ids:
                yield scenario, "none", mode, f"{i:03d}", (
                    base/scenario/mode/f"run-{i:03d}"
                )

    for profile in PROFILES:
        for mode in MODES:
            for i in (3, 4):
                yield "scenario-e", profile, mode, f"{i:03d}", (
                    base/"scenario-e"/profile/mode/f"run-{i:03d}"
                )

    for i in (3, 4):
        yield "scenario-c-d", "none", "FA1", f"{i:03d}", (
            base/"scenario-c-d"/"logical-runs"/f"run-{i:03d}"
        )

def metadata(path):
    result = {}
    for line in read(path).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            result[k.strip()] = v.strip()
    return result

def clinical_samples(path):
    if not path.exists():
        return 0, 0, 0

    seen = set()
    ok = 0
    bad = 0

    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            t = row.get("utc", "")
            if not t or t in seen:
                continue
            seen.add(t)
            if row.get("clinical_ok", "").lower() == "true":
                ok += 1
            else:
                bad += 1

    return len(seen), ok, bad

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--base", default="experiments/evaluation/openmrs"
    )
    ap.add_argument(
        "--output", default="analysis/results/openmrs"
    )
    args = ap.parse_args()

    base = Path(args.base).resolve()
    out = Path(args.output).resolve()

    inventory, metrics, warnings = [], [], []

    for scenario, profile, mode, run, directory in planned(base):
        state = status(directory)

        key = {
            "scenario": scenario,
            "profile": profile,
            "mode": mode,
            "run": run,
            "status": state,
            "directory": str(directory)
        }
        inventory.append(key)

        if state != "COMPLETE":
            continue

        issues = []

        if scenario == "scenario-c-d":
            pilot_path = read(directory/"pilot-directory.txt")
            pilot = Path(pilot_path) if pilot_path else None
            controller = read(pilot/"controller.log") if pilot else ""
            reconciliation = read(directory/"reconciliation.log")

            if not pilot or not pilot.is_dir():
                issues.append("MISSING_PILOT")
            if "[FENCING VERIFIED]" not in controller:
                issues.append("FENCING_NOT_VERIFIED")
            if "[RECOVERY VERIFIED]" not in controller:
                issues.append("RECOVERY_NOT_VERIFIED")
            if "RECONCILIATION_VERIFIED" not in reconciliation:
                issues.append("RECONCILIATION_NOT_VERIFIED")

            metrics.append({
                **key,
                "pilot_directory": pilot_path,
                "fencing_verified": "[FENCING VERIFIED]" in controller,
                "recovery_verified": "[RECOVERY VERIFIED]" in controller,
                "reconciliation_verified":
                    "RECONCILIATION_VERIFIED" in reconciliation,
                "quality_status": "REVIEW_REQUIRED" if issues else "CHECKS_PASSED",
                "quality_issues": ";".join(issues)
            })
        else:
            m = metadata(directory/"metadata.env")
            start = read(directory/"fault-time.txt") or read(
                directory/"fault-start-time.txt"
            )
            clear = read(directory/"fault-clear-time.txt")
            n, good, bad = clinical_samples(
                directory/"recovery-observations.csv"
            )

            if not start:
                issues.append("MISSING_FAULT_START")
            if not clear:
                issues.append("MISSING_FAULT_CLEAR")
            if n == 0:
                issues.append("NO_CLINICAL_SAMPLES")

            duration = seconds(start, clear)

            if duration == "":
                issues.append("INVALID_FAULT_TIMING")

            if scenario == "scenario-c" and not read(
                directory/"replacement-pod.txt"
            ):
                issues.append("MISSING_REPLACEMENT_RECORD")

            metrics.append({
                **key,
                "original_pod": m.get("original_pod", ""),
                "original_node": m.get("original_node", ""),
                "fault_start": start,
                "fault_clear": clear,
                "fault_duration_seconds": duration,
                "clinical_samples": n,
                "clinical_successes": good,
                "clinical_failures": bad,
                "clinical_success_pct":
                    round(100*good/n, 3) if n else "",
                "replacement_pod": read(
                    directory/"replacement-pod.txt"
                ),
                "quality_status": "REVIEW_REQUIRED" if issues else "CHECKS_PASSED",
                "quality_issues": ";".join(issues)
            })

        for issue in issues:
            warnings.append({
                "scenario": scenario,
                "profile": profile,
                "mode": mode,
                "run": run,
                "issue": issue
            })

    write_csv(out/"run-inventory.csv", inventory, [
        "scenario", "profile", "mode", "run", "status", "directory"
    ])

    columns = sorted({k for row in metrics for k in row})
    write_csv(out/"run-metrics.csv", metrics, columns or ["scenario"])

    write_csv(out/"quality-warnings.csv", warnings, [
        "scenario", "profile", "mode", "run", "issue"
    ])

    progress = []
    for scenario in ("scenario-b", "scenario-c", "scenario-c-d", "scenario-e"):
        group = [r for r in inventory if r["scenario"] == scenario]
        progress.append({
            "scenario": scenario,
            "planned": len(group),
            "complete": sum(r["status"] == "COMPLETE" for r in group),
            "incomplete": sum(r["status"] == "INCOMPLETE" for r in group),
            "missing": sum(r["status"] == "MISSING" for r in group)
        })

    write_csv(out/"progress-summary.csv", progress, [
        "scenario", "planned", "complete", "incomplete", "missing"
    ])

    for r in progress:
        print(
            f"{r['scenario']}: {r['complete']}/{r['planned']} complete, "
            f"{r['incomplete']} incomplete, {r['missing']} missing"
        )

    print("Quality warnings:", len(warnings))
    print("Output:", out)

if __name__ == "__main__":
    main()