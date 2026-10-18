#!/usr/bin/env python3
"""
Failure-Aware Kubernetes: isolated Nginx B/C reproduction.

Uses unchanged legacy extraction and summarization algorithms
inside a temporary workspace containing only Scenario B/C evidence.

Original evidence and historical results remain read-only.

Outputs:
  nginx-bc-run-metrics.csv
  nginx-bc-summary.csv
  nginx-bc-validation.csv
  nginx-scenario-b-population.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SOURCE = ROOT / "experiments/evaluation"
ANALYSIS = ROOT / "analysis"

DEFAULT_OUTPUT = (
    ROOT / "analysis/results/reproduced"
)

REFERENCE = (
    ROOT / "analysis/results/run-metrics.csv"
)

SCRIPTS = (
    "extract_metrics.py",
    "summarize_results.py",
)

SCENARIOS = (
    "scenario-b",
    "scenario-c",
)

MODES = (
    "native",
    "failure-aware",
)

VALIDATION_FIELDS = [
    "scenario",
    "mode",
    "run",
    "field",
    "historical_value",
    "reproduced_value",
    "status",
]

POPULATION_FIELDS = [
    "scenario",
    "mode",
    "run",
    "valid",
    "decision",
    "replacement_occurred",
    "historical_metric_present",
    "manuscript_cohort",
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


def run_key(row):
    return (
        row["scenario"],
        row["mode"],
        row["run"],
    )


def compare_metrics(historical, reproduced):
    old = {
        run_key(row): row
        for row in historical
        if row.get("scenario") in SCENARIOS
        and row.get("mode") in MODES
    }

    new = {
        run_key(row): row
        for row in reproduced
    }

    fields = sorted(
        set().union(
            *(row.keys() for row in old.values()),
            *(row.keys() for row in new.values()),
        )
    ) if old or new else []

    results = []

    for key in sorted(set(old) | set(new)):
        left = old.get(key)
        right = new.get(key)

        if left is None:
            results.append({
                "scenario": key[0],
                "mode": key[1],
                "run": key[2],
                "field": "*",
                "historical_value": "",
                "reproduced_value": "PRESENT",
                "status": "NEW_RUN",
            })
            continue

        if right is None:
            results.append({
                "scenario": key[0],
                "mode": key[1],
                "run": key[2],
                "field": "*",
                "historical_value": "PRESENT",
                "reproduced_value": "",
                "status": "MISSING_RUN",
            })
            continue

        for field in fields:
            a = (left.get(field) or "").strip()
            b = (right.get(field) or "").strip()

            if a == b:
                continue

            results.append({
                "scenario": key[0],
                "mode": key[1],
                "run": key[2],
                "field": field,
                "historical_value": a,
                "reproduced_value": b,
                "status": "VALUE_DIFFERENCE",
            })

    return results


def create_population(rows, historical):
    historical_keys = {
        run_key(row)
        for row in historical
    }

    population = []

    for row in rows:
        if (
            row.get("scenario") != "scenario-b"
            or row.get("mode") != "failure-aware"
        ):
            continue

        population.append({
            "scenario": row["scenario"],
            "mode": row["mode"],
            "run": row["run"],
            "valid": row.get("valid", ""),
            "decision": row.get("decision", ""),
            "replacement_occurred":
                row.get("replacement_occurred", ""),
            "historical_metric_present": (
                "YES"
                if run_key(row) in historical_keys
                else "NO"
            ),
            "manuscript_cohort":
                "NOT_DETERMINED",
        })

    return sorted(
        population,
        key=lambda row: row["run"],
    )


def run_legacy(script, workspace):
    command = [
        sys.executable,
        str(
            workspace / "analysis" / script
        ),
    ]

    result = subprocess.run(
        command,
        cwd=workspace,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"{script} failed:\n"
            f"{result.stdout}\n"
            f"{result.stderr}"
        )

    return result.stdout


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

    if not REFERENCE.is_file():
        parser.error(
            f"Historical metrics missing: {REFERENCE}"
        )

    with tempfile.TemporaryDirectory(
        prefix="failure-aware-nginx-"
    ) as temporary:
        workspace = Path(temporary)

        work_analysis = workspace / "analysis"
        work_evaluation = (
            workspace / "experiments/evaluation"
        )

        work_analysis.mkdir(
            parents=True,
            exist_ok=True,
        )

        work_evaluation.mkdir(
            parents=True,
            exist_ok=True,
        )

        for script in SCRIPTS:
            shutil.copy2(
                ANALYSIS / script,
                work_analysis / script,
            )

        for scenario in SCENARIOS:
            source = SOURCE / scenario
            target = work_evaluation / scenario

            if not source.is_dir():
                raise RuntimeError(
                    f"Missing scenario evidence: {source}"
                )

            # Links raw evidence without copying or changing it.
            target.symlink_to(
                source,
                target_is_directory=True,
            )

        print("Running original Nginx metric extractor")
        run_legacy(
            "extract_metrics.py",
            workspace,
        )

        print("Running original Nginx summarizer")
        run_legacy(
            "summarize_results.py",
            workspace,
        )

        generated = (
            workspace / "analysis/results"
        )

        metrics_path = generated / "run-metrics.csv"
        summary_path = generated / "summary.csv"

        reproduced = read_csv(metrics_path)
        historical = read_csv(REFERENCE)

        differences = compare_metrics(
            historical,
            reproduced,
        )

        population = create_population(
            reproduced,
            historical,
        )

        output.mkdir(
            parents=True,
            exist_ok=True,
        )

        shutil.copy2(
            metrics_path,
            output / "nginx-bc-run-metrics.csv",
        )

        shutil.copy2(
            summary_path,
            output / "nginx-bc-summary.csv",
        )

        write_csv(
            output / "nginx-bc-validation.csv",
            differences,
            VALIDATION_FIELDS,
        )

        write_csv(
            output / "nginx-scenario-b-population.csv",
            population,
            POPULATION_FIELDS,
        )

        print("NGINX_BC_REPRODUCTION_COMPLETE")
        print("Reproduced rows:", len(reproduced))
        print("Historical differences:", len(differences))
        print(
            "Scenario B FA1 entries:",
            len(population),
        )

        if differences:
            counts = Counter(
                row["status"]
                for row in differences
            )

            print(
                "Validation differences:",
                dict(counts),
            )

            print(
                "Inspect:",
                output / "nginx-bc-validation.csv",
            )

            return 1

        print("NGINX_BC_REFERENCE_COMPARISON_PASSED")
        return 0


if __name__ == "__main__":
    sys.exit(main())
