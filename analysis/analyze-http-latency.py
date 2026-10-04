#!/usr/bin/env python3

import csv
import math
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT_ROOT = REPO_ROOT / "experiments" / "evaluation"
RESULTS_DIR = REPO_ROOT / "analysis" / "results"

RUN_METRICS = RESULTS_DIR / "run-metrics.csv"

COMBINED_OUTPUT = RESULTS_DIR / "http_latency_observations.csv"
RUN_OUTPUT = RESULTS_DIR / "http_latency_by_run.csv"
SUMMARY_OUTPUT = RESULTS_DIR / "http_latency_summary.csv"


def parse_timestamp(value):
    if not value:
        return None

    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def parse_boolean(value):
    return value.strip().lower() in {"true", "1", "yes"}


def percentile(values, probability):
    if not values:
        return ""

    ordered = sorted(values)

    if len(ordered) == 1:
        return ordered[0]

    position = probability * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)

    if lower == upper:
        return ordered[lower]

    fraction = position - lower

    return (
        ordered[lower]
        + fraction * (ordered[upper] - ordered[lower])
    )


def read_timestamp_file(path):
    if not path.exists():
        return None

    value = path.read_text(encoding="utf-8").strip()
    return parse_timestamp(value) if value else None


def identify_run(path):
    parts = path.parts

    for index, part in enumerate(parts):
        if not part.startswith("scenario-"):
            continue

        if index + 2 >= len(parts):
            break

        return (
            part,
            parts[index + 1],
            parts[index + 2],
        )

    return None


def load_valid_runs():
    valid_runs = set()

    with RUN_METRICS.open(
        newline="",
        encoding="utf-8",
    ) as handle:
        for row in csv.DictReader(handle):
            if parse_boolean(row.get("valid", "")):
                valid_runs.add(
                    (
                        row["scenario"],
                        row["mode"],
                        row["run"],
                    )
                )

    return valid_runs


def classify_phase(timestamp, fault_time, fault_clear_time):
    if fault_time is None:
        return "unclassified"

    if timestamp < fault_time:
        return "pre_fault"

    if fault_clear_time is not None and timestamp >= fault_clear_time:
        return "post_clear"

    return "fault_window"


def consolidate():
    valid_runs = load_valid_runs()
    observations = []
    included_files = 0
    skipped_files = 0

    paths = sorted(
        EXPERIMENT_ROOT.rglob("http-observations.csv")
    )

    for path in paths:
        identity = identify_run(path)

        if identity is None:
            skipped_files += 1
            continue

        scenario, mode, run = identity

        if (scenario, mode, run) not in valid_runs:
            skipped_files += 1
            continue

        run_directory = path.parent

        fault_time = read_timestamp_file(
            run_directory / "fault-time.txt"
        )

        fault_clear_time = read_timestamp_file(
            run_directory / "fault-clear-time.txt"
        )

        with path.open(
            newline="",
            encoding="utf-8",
        ) as handle:
            reader = csv.DictReader(handle)

            expected = {
                "timestamp_utc",
                "node",
                "target_url",
                "status",
                "latency_ms",
                "success",
                "error",
            }

            if set(reader.fieldnames or []) != expected:
                raise SystemExit(
                    f"Unexpected HTTP schema: {path}"
                )

            for row in reader:
                timestamp = parse_timestamp(row["timestamp_utc"])

                if timestamp is None:
                    continue

                latency = ""

                if row["latency_ms"].strip():
                    latency = float(row["latency_ms"])

                observations.append(
                    {
                        "scenario": scenario,
                        "mode": mode,
                        "run": run,
                        "phase": classify_phase(
                            timestamp,
                            fault_time,
                            fault_clear_time,
                        ),
                        "timestamp_utc": row["timestamp_utc"],
                        "node": row["node"],
                        "target_url": row["target_url"],
                        "status": row["status"],
                        "latency_ms": latency,
                        "success": parse_boolean(row["success"]),
                        "error": row["error"],
                        "source_file": str(
                            path.relative_to(REPO_ROOT)
                        ),
                    }
                )

        included_files += 1

    return observations, included_files, skipped_files


def calculate_statistics(rows):
    total = len(rows)
    successful_rows = [
        row for row in rows
        if row["success"] and row["latency_ms"] != ""
    ]

    successful = len(successful_rows)
    failed = total - successful

    latencies = [
        float(row["latency_ms"])
        for row in successful_rows
    ]

    return {
        "total_requests": total,
        "successful_requests": successful,
        "failed_requests": failed,
        "success_rate_percent":
            (successful / total * 100) if total else "",
        "failure_rate_percent":
            (failed / total * 100) if total else "",
        "latency_mean_ms":
            statistics.fmean(latencies) if latencies else "",
        "latency_median_ms":
            statistics.median(latencies) if latencies else "",
        "latency_p95_ms":
            percentile(latencies, 0.95),
        "latency_p99_ms":
            percentile(latencies, 0.99),
        "latency_min_ms":
            min(latencies) if latencies else "",
        "latency_max_ms":
            max(latencies) if latencies else "",
        "latency_stddev_ms":
            statistics.stdev(latencies)
            if len(latencies) > 1 else 0.0,
    }


def build_run_summary(observations):
    groups = defaultdict(list)

    for row in observations:
        key = (
            row["scenario"],
            row["mode"],
            row["run"],
            row["phase"],
        )
        groups[key].append(row)

    results = []

    for key, rows in sorted(groups.items()):
        scenario, mode, run, phase = key

        results.append(
            {
                "scenario": scenario,
                "mode": mode,
                "run": run,
                "phase": phase,
                **calculate_statistics(rows),
            }
        )

    return results


def build_overall_summary(observations):
    groups = defaultdict(list)
    run_sets = defaultdict(set)

    for row in observations:
        key = (
            row["scenario"],
            row["mode"],
            row["phase"],
        )

        groups[key].append(row)
        run_sets[key].add(row["run"])

    results = []

    for key, rows in sorted(groups.items()):
        scenario, mode, phase = key

        results.append(
            {
                "scenario": scenario,
                "mode": mode,
                "phase": phase,
                "runs": len(run_sets[key]),
                **calculate_statistics(rows),
            }
        )

    return results


def write_csv(path, rows, fields):
    if path.exists():
        raise SystemExit(
            f"Refusing to overwrite existing result: {path}"
        )

    with path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fields,
        )
        writer.writeheader()
        writer.writerows(rows)


def main():
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    observations, included, skipped = consolidate()

    observation_fields = [
        "scenario",
        "mode",
        "run",
        "phase",
        "timestamp_utc",
        "node",
        "target_url",
        "status",
        "latency_ms",
        "success",
        "error",
        "source_file",
    ]

    statistic_fields = [
        "total_requests",
        "successful_requests",
        "failed_requests",
        "success_rate_percent",
        "failure_rate_percent",
        "latency_mean_ms",
        "latency_median_ms",
        "latency_p95_ms",
        "latency_p99_ms",
        "latency_min_ms",
        "latency_max_ms",
        "latency_stddev_ms",
    ]

    run_summary = build_run_summary(observations)
    overall_summary = build_overall_summary(observations)

    write_csv(
        COMBINED_OUTPUT,
        observations,
        observation_fields,
    )

    write_csv(
        RUN_OUTPUT,
        run_summary,
        [
            "scenario",
            "mode",
            "run",
            "phase",
            *statistic_fields,
        ],
    )

    write_csv(
        SUMMARY_OUTPUT,
        overall_summary,
        [
            "scenario",
            "mode",
            "phase",
            "runs",
            *statistic_fields,
        ],
    )

    print(f"Source files discovered : 126")
    print(f"Source files included   : {included}")
    print(f"Source files skipped    : {skipped}")
    print(f"HTTP observations       : {len(observations)}")
    print(f"Combined observations   : {COMBINED_OUTPUT}")
    print(f"Per-run summary         : {RUN_OUTPUT}")
    print(f"Overall summary         : {SUMMARY_OUTPUT}")


if __name__ == "__main__":
    main()