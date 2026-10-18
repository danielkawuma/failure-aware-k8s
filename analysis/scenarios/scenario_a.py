#!/usr/bin/env python3
"""
Failure-Aware Kubernetes: Scenario A results reproduction.

Uses the original Scenario A analysis implementation in an
isolated workspace and applies the frozen manuscript cohort.

Outputs:
  scenario-a-all-attempts.csv
  scenario-a-run-metrics.csv
  scenario-a-summary.csv
  scenario-a-validation.csv

No experiments are executed.
Original evidence remains read-only.
"""

from __future__ import annotations

import argparse
import csv
import shutil
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SOURCE = ROOT / "experiments/evaluation/scenario-a"

LEGACY_ANALYZER = (
    ROOT / "analysis/analyze-scenario-a.py"
)

COHORT = (
    ROOT / "analysis/reference/"
    "scenario-a-manuscript-cohort.csv"
)

DEFAULT_OUTPUT = (
    ROOT / "analysis/results/reproduced"
)

METRICS = [
    "suspicion_delay_s",
    "decision_delay_s",
    "replacement_running_s",
    "k3s_http_outage_s",
    "single_http_outage_s",
]

SUMMARY_FIELDS = [
    "arm",
    "metric",
    "n",
    "mean",
    "sd",
    "median",
    "min",
    "max",
]

VALIDATION_FIELDS = [
    "arm",
    "run",
    "status",
    "included",
    "issue",
]


def read_csv(path):
    with path.open(
        newline="",
        encoding="utf-8",
    ) as handle:
        return list(csv.DictReader(handle))


def write_csv(path, rows, fields):
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
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


def numeric(value):
    if value in (
        None,
        "",
        "not recorded",
        "NOT_RECORDED",
    ):
        return None

    try:
        return float(value)
    except ValueError:
        return None


def load_cohort():
    rows = read_csv(COHORT)

    cohort = {}

    for row in rows:
        key = (
            row["mode"],
            row["run_id"],
        )

        if key in cohort:
            raise ValueError(
                f"Duplicate cohort entry: {key}"
            )

        cohort[key] = (
            row["include"].strip().lower()
            == "true"
        )

    return cohort


def summarize(rows):
    summary = []

    for arm in ("native", "failure-aware"):
        arm_rows = [
            row for row in rows
            if row["arm"] == arm
        ]

        for metric in METRICS:
            values = [
                value
                for row in arm_rows
                if (
                    value := numeric(
                        row.get(metric)
                    )
                ) is not None
            ]

            summary.append({
                "arm": arm,
                "metric": metric,
                "n": len(values),
                "mean": (
                    statistics.mean(values)
                    if values else ""
                ),
                "sd": (
                    statistics.stdev(values)
                    if len(values) > 1 else ""
                ),
                "median": (
                    statistics.median(values)
                    if values else ""
                ),
                "min": (
                    min(values)
                    if values else ""
                ),
                "max": (
                    max(values)
                    if values else ""
                ),
            })

    return summary


def run_legacy():
    if not SOURCE.is_dir():
        raise FileNotFoundError(
            f"Scenario A evidence missing: {SOURCE}"
        )

    if not LEGACY_ANALYZER.is_file():
        raise FileNotFoundError(
            f"Legacy analyzer missing: {LEGACY_ANALYZER}"
        )

    with tempfile.TemporaryDirectory(
        prefix="failure-aware-scenario-a-"
    ) as temporary:
        workspace = Path(temporary)

        analysis = workspace / "analysis"
        evidence = (
            workspace
            / "experiments/evaluation/scenario-a"
        )

        analysis.mkdir(
            parents=True,
            exist_ok=True,
        )

        evidence.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        shutil.copy2(
            LEGACY_ANALYZER,
            analysis / "analyze-scenario-a.py",
        )

        evidence.symlink_to(
            SOURCE,
            target_is_directory=True,
        )

        result = subprocess.run(
            [
                sys.executable,
                str(
                    analysis
                    / "analyze-scenario-a.py"
                ),
            ],
            cwd=workspace,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )

        if result.returncode != 0:
            raise RuntimeError(
                "Legacy Scenario A analysis failed:\n"
                + result.stdout
                + result.stderr
            )

        metrics_path = (
            workspace
            / "analysis/results/scenario-a/run-metrics.csv"
        )

        if not metrics_path.is_file():
            raise RuntimeError(
                "Legacy analyzer did not produce run metrics"
            )

        return read_csv(metrics_path)


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
    )

    args = parser.parse_args()

    output = args.output.resolve()

    if output != DEFAULT_OUTPUT.resolve():
        parser.error(
            "Output must be analysis/results/reproduced"
        )

    cohort = load_cohort()
    attempts = run_legacy()

    included = []
    validation = []
    observed_keys = set()

    for row in attempts:
        key = (
            row["arm"],
            row["run"],
        )

        if key in observed_keys:
            raise ValueError(
                f"Duplicate experimental run: {key}"
            )

        observed_keys.add(key)

        if key not in cohort:
            validation.append({
                "arm": key[0],
                "run": key[1],
                "status": row["status"],
                "included": "NO",
                "issue": "RUN_NOT_IN_FROZEN_COHORT",
            })
            continue

        should_include = cohort[key]

        if should_include:
            if row["status"] != "COMPLETE":
                validation.append({
                    "arm": key[0],
                    "run": key[1],
                    "status": row["status"],
                    "included": "YES",
                    "issue": "INCLUDED_RUN_NOT_COMPLETE",
                })
                continue

            included.append(row)

        else:
            validation.append({
                "arm": key[0],
                "run": key[1],
                "status": row["status"],
                "included": "NO",
                "issue": "INCOMPLETE_ATTEMPT_EXCLUDED",
            })

    for key in cohort:
        if key not in observed_keys:
            validation.append({
                "arm": key[0],
                "run": key[1],
                "status": "MISSING",
                "included": (
                    "YES" if cohort[key] else "NO"
                ),
                "issue": "COHORT_RUN_MISSING",
            })

    native = sum(
        row["arm"] == "native"
        for row in included
    )

    failure_aware = sum(
        row["arm"] == "failure-aware"
        for row in included
    )

    if native != 5 or failure_aware != 5:
        raise RuntimeError(
            "Frozen cohort validation failed: "
            f"native={native}, failure-aware={failure_aware}"
        )

    fields = list(attempts[0]) if attempts else []

    write_csv(
        output / "scenario-a-all-attempts.csv",
        attempts,
        fields,
    )

    write_csv(
        output / "scenario-a-run-metrics.csv",
        included,
        fields,
    )

    write_csv(
        output / "scenario-a-summary.csv",
        summarize(included),
        SUMMARY_FIELDS,
    )

    write_csv(
        output / "scenario-a-validation.csv",
        validation,
        VALIDATION_FIELDS,
    )

    print("SCENARIO_A_REPRODUCTION_COMPLETE")
    print("All attempts:", len(attempts))
    print("Native included:", native)
    print("Failure-Aware included:", failure_aware)
    print("Validation records:", len(validation))
    print("Output:", output)

    return 0


if __name__ == "__main__":
    sys.exit(main())
