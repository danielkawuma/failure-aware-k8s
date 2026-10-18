#!/usr/bin/env python3
"""
Failure-Aware Kubernetes: Nginx B/C results reproduction.

Reuses the original extraction and summarization algorithms
inside an isolated temporary workspace.

Populations:
  manuscript: historical Scenario B FA1 cohort from 2120ac4
  historical: runs present in preserved October metrics
  current: all currently discovered B/C runs

No experiment execution or raw evidence modification.
"""

from __future__ import annotations

import argparse
import csv
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ANALYSIS = ROOT / "analysis"
EVALUATION = ROOT / "experiments/evaluation"

OUTPUT = ANALYSIS / "results/reproduced"

MANUSCRIPT_REFERENCE = (
    ANALYSIS / "reference/nginx-historical-run-metrics.csv"
)

MANUSCRIPT_COHORT = (
    ANALYSIS / "reference/nginx-scenario-b-manuscript-cohort.csv"
)

HISTORICAL_REFERENCE = (
    ANALYSIS / "results/run-metrics.csv"
)

SCENARIOS = ("scenario-b", "scenario-c")
MODES = ("native", "failure-aware")

KEY_FIELDS = ("scenario", "mode", "run")

VALIDATION_FIELDS = [
    "population",
    "scenario",
    "mode",
    "run",
    "field",
    "expected",
    "actual",
    "status",
]

POPULATION_FIELDS = [
    "scenario",
    "mode",
    "run",
    "valid",
    "decision",
    "replacement_occurred",
    "manuscript_member",
    "historical_member",
    "population_class",
]


def read_csv(path):
    with path.open(
        newline="",
        encoding="utf-8",
    ) as handle:
        return list(csv.DictReader(handle))


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fields,
            extrasaction="ignore",
        )
        writer.writeheader()
        writer.writerows(rows)


def key(row):
    return tuple(row[field] for field in KEY_FIELDS)


def is_bc(row):
    return (
        row.get("scenario") in SCENARIOS
        and row.get("mode") in MODES
    )


def index_rows(rows, label):
    indexed = {}

    for row in rows:
        identifier = key(row)

        if identifier in indexed:
            raise ValueError(
                f"Duplicate {label} run: {identifier}"
            )

        indexed[identifier] = row

    return indexed


def load_manuscript_cohort():
    rows = read_csv(MANUSCRIPT_COHORT)
    members = set()

    for row in rows:
        if row["include"].lower() != "true":
            continue

        identifier = key(row)

        if identifier in members:
            raise ValueError(
                f"Duplicate manuscript member: {identifier}"
            )

        members.add(identifier)

    if len(members) != 33:
        raise ValueError(
            f"Expected 33 manuscript FA1 runs; got {len(members)}"
        )

    return members


def execute_legacy(script, workspace):
    result = subprocess.run(
        [
            sys.executable,
            str(workspace / "analysis" / script),
        ],
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


def extract_current():
    with tempfile.TemporaryDirectory(
        prefix="failure-aware-nginx-"
    ) as temporary:
        workspace = Path(temporary)
        analysis = workspace / "analysis"
        evaluation = workspace / "experiments/evaluation"

        analysis.mkdir(parents=True)
        evaluation.mkdir(parents=True)

        for script in (
            "extract_metrics.py",
            "summarize_results.py",
        ):
            shutil.copy2(
                ANALYSIS / script,
                analysis / script,
            )

        for scenario in SCENARIOS:
            source = EVALUATION / scenario

            if not source.is_dir():
                raise FileNotFoundError(source)

            (evaluation / scenario).symlink_to(
                source,
                target_is_directory=True,
            )

        execute_legacy("extract_metrics.py", workspace)
        execute_legacy("summarize_results.py", workspace)

        generated = workspace / "analysis/results"

        return (
            read_csv(generated / "run-metrics.csv"),
            read_csv(generated / "summary.csv"),
        )


def compare(reference, current, population):
    expected = index_rows(reference, population + " reference")
    actual = index_rows(current, population + " reproduced")

    differences = []

    for identifier in sorted(expected):
        old = expected[identifier]
        new = actual.get(identifier)

        if new is None:
            differences.append({
                "population": population,
                "scenario": identifier[0],
                "mode": identifier[1],
                "run": identifier[2],
                "field": "*",
                "expected": "PRESENT",
                "actual": "MISSING",
                "status": "MISSING_RUN",
            })
            continue

        for field in old:
            a = (old.get(field) or "").strip()
            b = (new.get(field) or "").strip()

            if a != b:
                differences.append({
                    "population": population,
                    "scenario": identifier[0],
                    "mode": identifier[1],
                    "run": identifier[2],
                    "field": field,
                    "expected": a,
                    "actual": b,
                    "status": "VALUE_DIFFERENCE",
                })

    return differences


def summarize_population(rows):
    """
    Execute the original summary algorithm on an explicitly
    selected population, without modifying historical outputs.
    """
    with tempfile.TemporaryDirectory(
        prefix="failure-aware-nginx-summary-"
    ) as temporary:
        workspace = Path(temporary)
        analysis = workspace / "analysis"
        results = analysis / "results"

        results.mkdir(parents=True)

        shutil.copy2(
            ANALYSIS / "summarize_results.py",
            analysis / "summarize_results.py",
        )

        source_fields = list(
            read_csv(HISTORICAL_REFERENCE)[0]
        )

        write_csv(
            results / "run-metrics.csv",
            rows,
            source_fields,
        )

        execute_legacy(
            "summarize_results.py",
            workspace,
        )

        return read_csv(results / "summary.csv")


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT,
    )

    args = parser.parse_args()

    output = args.output.resolve()

    if output != OUTPUT.resolve():
        parser.error(
            "Output must be analysis/results/reproduced"
        )

    for path in (
        MANUSCRIPT_REFERENCE,
        MANUSCRIPT_COHORT,
        HISTORICAL_REFERENCE,
    ):
        if not path.is_file():
            parser.error(f"Missing reference: {path}")

    manuscript_members = load_manuscript_cohort()

    historical_all = [
        row for row in read_csv(HISTORICAL_REFERENCE)
        if is_bc(row)
    ]

    manuscript_reference = [
        row for row in read_csv(MANUSCRIPT_REFERENCE)
        if key(row) in manuscript_members
    ]

    if len(manuscript_reference) != 33:
        raise ValueError(
            "Historical manuscript reference is incomplete"
        )

    current, _ = extract_current()

    current = [
        row for row in current
        if is_bc(row)
    ]

    current_index = index_rows(current, "current")
    historical_index = index_rows(
        historical_all, "historical"
    )

    manuscript_rows = [
        current_index[identifier]
        for identifier in sorted(manuscript_members)
        if identifier in current_index
    ]

    historical_rows = [
        current_index[identifier]
        for identifier in sorted(historical_index)
        if identifier in current_index
    ]

    differences = []

    differences.extend(
        compare(
            manuscript_reference,
            manuscript_rows,
            "manuscript",
        )
    )

    differences.extend(
        compare(
            historical_all,
            historical_rows,
            "historical",
        )
    )

    population = []

    for row in current:
        identifier = key(row)

        if identifier in manuscript_members:
            classification = "MANUSCRIPT"
        elif identifier in historical_index:
            classification = "HISTORICAL_SUPPLEMENTARY"
        else:
            classification = "ADDITIONAL"

        population.append({
            "scenario": row["scenario"],
            "mode": row["mode"],
            "run": row["run"],
            "valid": row.get("valid", ""),
            "decision": row.get("decision", ""),
            "replacement_occurred":
                row.get("replacement_occurred", ""),
            "manuscript_member":
                "YES" if identifier in manuscript_members else "NO",
            "historical_member":
                "YES" if identifier in historical_index else "NO",
            "population_class": classification,
        })

    manuscript_summary = summarize_population(
        manuscript_rows
    )

    historical_summary = summarize_population(
        historical_rows
    )

    current_summary = summarize_population(current)

    output.mkdir(parents=True, exist_ok=True)

    metric_fields = list(
        read_csv(HISTORICAL_REFERENCE)[0]
    )

    write_csv(
        output / "nginx-bc-current-metrics.csv",
        current,
        metric_fields,
    )

    write_csv(
        output / "nginx-bc-historical-metrics.csv",
        historical_rows,
        metric_fields,
    )

    write_csv(
        output / "nginx-scenario-b-manuscript-metrics.csv",
        manuscript_rows,
        metric_fields,
    )

    summary_fields = list(current_summary[0])

    for name, rows in (
        ("nginx-bc-current-summary.csv", current_summary),
        ("nginx-bc-historical-summary.csv", historical_summary),
        ("nginx-scenario-b-manuscript-summary.csv", manuscript_summary),
    ):
        write_csv(
            output / name,
            rows,
            summary_fields,
        )

    write_csv(
        output / "nginx-bc-validation.csv",
        differences,
        VALIDATION_FIELDS,
    )

    write_csv(
        output / "nginx-bc-population.csv",
        population,
        POPULATION_FIELDS,
    )

    fa1_current = [
        row for row in current
        if row["scenario"] == "scenario-b"
        and row["mode"] == "failure-aware"
    ]

    fa1_historical = [
        row for row in historical_rows
        if row["scenario"] == "scenario-b"
        and row["mode"] == "failure-aware"
    ]

    print("NGINX_BC_REPRODUCTION_COMPLETE")
    print("Manuscript FA1 runs:", len(manuscript_rows))
    print("Historical FA1 runs:", len(fa1_historical))
    print("Current FA1 runs:", len(fa1_current))
    print("Historical metric differences:", len(differences))
    print("Output:", output)

    if differences:
        counts = Counter(
            row["status"] for row in differences
        )

        print("VALIDATION_FAILED:", dict(counts))
        return 1

    print("NGINX_BC_HISTORICAL_VALIDATION_PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
