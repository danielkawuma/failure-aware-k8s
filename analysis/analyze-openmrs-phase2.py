
#!/usr/bin/env python3
"""Consolidated, evidence-aware OpenMRS Phase II analysis.

Reads experiment artifacts without modifying them.
Uses planned run IDs only.
Does not infer controller verification from Pod readiness.
"""

import argparse
import csv
import re
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path

MODES = ("V0", "T5", "T10", "T30", "FA1")
PROFILES = ("mild", "moderate", "severe")
CLINICAL_RE = re.compile(
    r"^\[CLINICAL\]\s+(\S+)\s+\|\s+"
    r"status=(\d+)\s+\|\s+"
    r"latency=([\d.]+)ms\s+\|\s+"
    r"success=(true|false)",
    re.I,
)

def read(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""

def timestamp(value):
    try:
        return datetime.fromisoformat(
            value.replace("Z", "+00:00")
        ) if value else None
    except (ValueError, AttributeError):
        return None

def elapsed(start, end):
    a, b = timestamp(start), timestamp(end)
    if a is None or b is None or b < a:
        return ""
    return round((b - a).total_seconds(), 3)

def metadata(path):
    result = {}
    for line in read(path).splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result

def csv_rows(path):
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def write_csv(path, rows, columns):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f, fieldnames=columns, extrasaction="ignore"
        )
        writer.writeheader()
        writer.writerows(rows)

def planned(base):
    for scenario, ids in (
        ("scenario-b", (3, 4, 5)),
        ("scenario-c", (3, 4)),
    ):
        for mode in MODES:
            for i in ids:
                yield (
                    scenario, "none", mode, f"{i:03d}",
                    base / scenario / mode / f"run-{i:03d}"
                )

    for profile in PROFILES:
        for mode in MODES:
            for i in (3, 4):
                yield (
                    "scenario-e", profile, mode, f"{i:03d}",
                    base / "scenario-e" / profile /
                    mode / f"run-{i:03d}"
                )

    for i in (3, 4):
        yield (
            "scenario-c-d", "none", "FA1", f"{i:03d}",
            base / "scenario-c-d" / "logical-runs" /
            f"run-{i:03d}"
        )

def run_status(directory):
    if not directory.exists():
        return "MISSING"
    if (
        (directory / "COMPLETE").is_file()
        and not (directory / "INCOMPLETE").exists()
    ):
        return "COMPLETE"
    return "INCOMPLETE"

def harness_samples(directory):
    samples = []
    for line in read(directory / "harness.log").splitlines():
        match = CLINICAL_RE.search(line)
        if not match:
            continue
        t, code, latency, success = match.groups()
        if timestamp(t) is None:
            continue
        samples.append({
            "utc": t,
            "status": int(code),
            "latency_ms": float(latency),
            "success": success.lower() == "true",
        })
    return samples

def observation_samples(directory):
    samples = []
    for row in csv_rows(
        directory / "recovery-observations.csv"
    ):
        t = row.get("utc", "")
        value = row.get("clinical_ok", "").lower()
        if timestamp(t) is None or value not in ("true", "false"):
            continue
        samples.append({
            "utc": t,
            "status": "",
            "latency_ms": "",
            "success": value == "true",
        })
    return samples

def clinical_metrics(samples):
    samples = sorted(
        samples, key=lambda r: timestamp(r["utc"])
    )
    count = len(samples)
    good = sum(s["success"] for s in samples)
    failures = count - good

    episodes = []
    first_failure = None

    for sample in samples:
        t = timestamp(sample["utc"])
        if not sample["success"] and first_failure is None:
            first_failure = t
        elif sample["success"] and first_failure is not None:
            episodes.append(
                (t - first_failure).total_seconds()
            )
            first_failure = None

    censored = first_failure is not None
    latencies = [
        s["latency_ms"] for s in samples
        if s["success"] and s["latency_ms"] != ""
    ]

    return {
        "clinical_samples": count,
        "clinical_successes": good,
        "clinical_failures": failures,
        "clinical_success_pct":
            round(100 * good / count, 3) if count else "",
        "successful_latency_median_ms":
            round(statistics.median(latencies), 3)
            if latencies else "",
        "outage_episodes":
            len(episodes) + int(censored),
        "resolved_outage_seconds":
            round(sum(episodes), 3) if episodes else "",
        "longest_resolved_episode_seconds":
            round(max(episodes), 3) if episodes else "",
        "right_censored": censored,
    }

def recovery_metrics(directory, start, clear, original, node):
    records = csv_rows(
        directory / "recovery-observations.csv"
    )

    replacement = read(directory / "replacement-pod.txt")
    restored = read(
        directory / "clinical-restored-observed-time.txt"
    )
    ready_marker = read(
        directory / "replacement-ready-observed-time.txt"
    )
    created = read(
        directory / "replacement-created-time.txt"
    )
    outcome = read(directory / "recovery-outcome.txt")
    controller = read(directory / "controller.log")

    observed_replacements = []
    for row in records:
        pod = row.get("pod", "")
        current_node = row.get("node", "")
        if (
            original and node and pod
            and pod != original
            and current_node
            and current_node != node
            and row.get("ready", "").lower() == "true"
            and timestamp(row.get("utc", ""))
        ):
            observed_replacements.append(row["utc"])

    observed_ready = (
        min(observed_replacements, key=timestamp)
        if observed_replacements else ""
    )

    ready = ready_marker or observed_ready

    if ready_marker and observed_ready:
        # Preserve both sources; do not silently overwrite a conflict.
        ready_disagreement = abs(
            (timestamp(ready_marker) -
             timestamp(observed_ready)).total_seconds()
        )
    else:
        ready_disagreement = ""

    recovery_phase = "NOT_OBSERVED"
    if restored and timestamp(restored):
        if clear and timestamp(clear):
            recovery_phase = (
                "DURING_FAULT"
                if timestamp(restored) < timestamp(clear)
                else "AFTER_CLEARANCE"
            )
        else:
            recovery_phase = "CLEARANCE_UNKNOWN"

    controller_verified = (
        "[RECOVERY VERIFIED]" in controller
        and "[RECOVERY UNVERIFIED]" not in controller
    )

    return {
        "replacement_pod": replacement,
        "replacement_created_time": created,
        "replacement_ready_time": ready,
        "replacement_ready_observed_time": observed_ready,
        "ready_marker_disagreement_seconds": ready_disagreement,
        "clinical_restored_time": restored,
        "fault_to_replacement_ready_seconds":
            elapsed(start, ready),
        "fault_to_clinical_restoration_seconds":
            elapsed(start, restored),
        "fault_clear_to_clinical_restoration_seconds":
            elapsed(clear, restored),
        "recovery_phase": recovery_phase,
        "recovery_outcome": outcome,
        "controller_recovery_verified": controller_verified,
        "controller_recovery_unverified":
            "[RECOVERY UNVERIFIED]" in controller,
    }

def summarize(rows):
    groups = defaultdict(list)
    fields = (
        "fault_duration_seconds",
        "clinical_success_pct",
        "successful_latency_median_ms",
        "fault_to_replacement_ready_seconds",
        "fault_to_clinical_restoration_seconds",
    )

    for row in rows:
        if row["status"] != "COMPLETE":
            continue
        for field in fields:
            value = row.get(field, "")
            if value == "" or value is None:
                continue
            try:
                number = float(value)
            except (ValueError, TypeError):
                continue
            key = (
                row["scenario"], row["profile"],
                row["mode"], field
            )
            groups[key].append(number)

    output = []
    for key, values in sorted(groups.items()):
        output.append({
            "scenario": key[0],
            "profile": key[1],
            "mode": key[2],
            "metric": key[3],
            "n": len(values),
            "mean": round(statistics.mean(values), 3),
            "median": round(statistics.median(values), 3),
            "sd": round(statistics.stdev(values), 3)
                if len(values) > 1 else "",
            "minimum": round(min(values), 3),
            "maximum": round(max(values), 3),
        })
    return output

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base",
        default="experiments/evaluation/openmrs"
    )
    parser.add_argument(
        "--output",
        default="analysis/results/openmrs-phase2-audit"
    )
    args = parser.parse_args()

    base = Path(args.base).resolve()
    out = Path(args.output).resolve()
    if not base.is_dir():
        parser.error(f"Experiment directory missing: {base}")

    inventory = []
    metrics = []
    warnings = []

    for scenario, profile, mode, run, directory in planned(base):
        state = run_status(directory)
        key = {
            "scenario": scenario,
            "profile": profile,
            "mode": mode,
            "run": run,
            "status": state,
            "directory": str(directory),
        }
        inventory.append(key)

        if state != "COMPLETE":
            continue

        issues = []
        m = metadata(directory / "metadata.env")
        start = (
            read(directory / "fault-time.txt")
            or read(directory / "fault-start-time.txt")
        )
        clear = read(directory / "fault-clear-time.txt")

        row = {
            **key,
            "original_pod": m.get("original_pod", ""),
            "original_node": m.get("original_node", ""),
            "fault_start": start,
            "fault_clear": clear,
            "fault_duration_seconds": elapsed(start, clear),
            "fault_clear_reason":
                read(directory / "fault-clear-reason.txt"),
        }

        if scenario == "scenario-c-d":
            issues.append("CD_REQUIRES_SEPARATE_FENCING_AUDIT")
        else:
            harness = harness_samples(directory)
            observations = observation_samples(directory)

            # Prefer the independent clinical HTTP probe.
            # Pod observation snapshots are not independent HTTP
            # requests and must not inflate the sample count.
            samples = harness if harness else observations
            row["clinical_source"] = (
                "harness.log" if harness else
                "recovery-observations.csv" if observations
                else "none"
            )
            row.update(clinical_metrics(samples))

            if not samples:
                issues.append("NO_CLINICAL_SAMPLES")
            if not start or not clear:
                issues.append("MISSING_FAULT_TIMESTAMPS")
            if row["fault_duration_seconds"] == "":
                issues.append("INVALID_FAULT_DURATION")

            if scenario == "scenario-c":
                row.update(recovery_metrics(
                    directory, start, clear,
                    row["original_pod"],
                    row["original_node"]
                ))
                if not row["clinical_restored_time"]:
                    issues.append("NO_RESTORATION_TIMESTAMP")
                if not row["replacement_ready_time"]:
                    issues.append("NO_REPLACEMENT_READY_TIMESTAMP")
                if row["controller_recovery_unverified"]:
                    issues.append("CONTROLLER_RECOVERY_UNVERIFIED")

        row["quality_issues"] = ";".join(issues)
        row["quality_status"] = (
            "REVIEW_REQUIRED" if issues else "CHECKS_PASSED"
        )
        metrics.append(row)

        for issue in issues:
            warnings.append({
                "scenario": scenario,
                "profile": profile,
                "mode": mode,
                "run": run,
                "issue": issue,
            })

    write_csv(
        out / "run-inventory.csv", inventory,
        ["scenario", "profile", "mode", "run",
         "status", "directory"]
    )

    columns = sorted({
        key for row in metrics for key in row
    })
    write_csv(
        out / "run-metrics.csv",
        metrics, columns or ["scenario"]
    )

    write_csv(
        out / "quality-warnings.csv", warnings,
        ["scenario", "profile", "mode", "run", "issue"]
    )

    summary = summarize(metrics)
    write_csv(
        out / "grouped-summary.csv", summary,
        ["scenario", "profile", "mode", "metric",
         "n", "mean", "median", "sd",
         "minimum", "maximum"]
    )

    progress = []
    for scenario in (
        "scenario-b", "scenario-c",
        "scenario-c-d", "scenario-e"
    ):
        group = [
            r for r in inventory if r["scenario"] == scenario
        ]
        progress.append({
            "scenario": scenario,
            "planned": len(group),
            "complete": sum(
                r["status"] == "COMPLETE" for r in group
            ),
            "incomplete": sum(
                r["status"] == "INCOMPLETE" for r in group
            ),
            "missing": sum(
                r["status"] == "MISSING" for r in group
            ),
        })

    write_csv(
        out / "progress-summary.csv", progress,
        ["scenario", "planned", "complete",
         "incomplete", "missing"]
    )

    for row in progress:
        print(
            f"{row['scenario']}: "
            f"{row['complete']}/{row['planned']} complete"
        )

    print("Quality warnings:", len(warnings))
    print("Grouped statistics:", len(summary))
    print("Output:", out)

if __name__ == "__main__":
    main()
