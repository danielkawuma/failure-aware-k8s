#!/usr/bin/env python3
"""
Failure-Aware Kubernetes: manuscript analysis components.

Reproduces:
- Scenario D/E outcomes
- OpenMRS clinical availability
- OpenMRS fencing
- OpenMRS Phase 2 metrics
- OpenMRS grouped statistics
- Controller overhead
- HTTP latency

Original experimental evidence and historical outputs are read-only.
Legacy scripts with fixed paths execute in temporary workspaces.

No experiment, SSH, Kubernetes or fault-injection command is run.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ANALYSIS = ROOT / "analysis"
EVALUATION = ROOT / "experiments/evaluation"
OUTPUT = ANALYSIS / "results/reproduced"
HISTORICAL = ANALYSIS / "results"

STAGES = [
    "scenario_d_e",
    "openmrs_clinical",
    "openmrs_fencing",
    "openmrs_phase2",
    "openmrs_statistics",
    "controller_overhead",
    "http_latency",
]

ARTIFACTS = {
    "scenario_d_e": [
        "scenario-d-e-results.csv",
    ],
    "openmrs_clinical": [
        "openmrs-clinical-metrics.csv",
    ],
    "openmrs_fencing": [
        "openmrs-fencing-metrics.csv",
    ],
    "openmrs_phase2": [
        "openmrs-phase2/run-inventory.csv",
        "openmrs-phase2/run-metrics.csv",
        "openmrs-phase2/quality-warnings.csv",
        "openmrs-phase2/grouped-summary.csv",
        "openmrs-phase2/progress-summary.csv",
    ],
    "openmrs_statistics": [
        "openmrs-grouped-statistics.csv",
    ],
    "controller_overhead": [
        "controller-overhead-runs.csv",
        "controller-overhead-summary.csv",
    ],
    "http_latency": [
        "http-latency-observations.csv",
        "http-latency-by-run.csv",
        "http-latency-summary.csv",
    ],
}

HISTORICAL_NAMES = {
    "scenario-d-e-results.csv":
        "new-experiment-d-e-results.csv",
    "openmrs-clinical-metrics.csv":
        "openmrs/clinical-metrics.csv",
    "openmrs-fencing-metrics.csv":
        "openmrs/fencing-metrics.csv",
    "controller-overhead-runs.csv":
        "controller_overhead_runs.csv",
    "controller-overhead-summary.csv":
        "controller_overhead_summary.csv",
    "http-latency-observations.csv":
        "http_latency_observations.csv",
    "http-latency-by-run.csv":
        "http_latency_by_run.csv",
    "http-latency-summary.csv":
        "http_latency_summary.csv",
}

MANIFEST_FIELDS = [
    "stage",
    "output",
    "rows",
    "sha256",
    "historical_reference",
    "comparison",
]


def digest(path):
    h = hashlib.sha256()

    with path.open("rb") as f:
        for chunk in iter(
            lambda: f.read(1024 * 1024), b""
        ):
            h.update(chunk)

    return h.hexdigest()


def read_csv(path):
    with path.open(
        newline="", encoding="utf-8-sig"
    ) as f:
        return list(csv.DictReader(f))


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open(
        "w", newline="", encoding="utf-8"
    ) as f:
        writer = csv.DictWriter(
            f, fieldnames=fields,
            extrasaction="ignore"
        )
        writer.writeheader()
        writer.writerows(rows)


def execute(script, args, cwd):
    command = [
        sys.executable,
        str(script),
        *[str(x) for x in args],
    ]

    result = subprocess.run(
        command,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
        timeout=600,
    )

    if result.returncode:
        raise RuntimeError(
            f"{script.name} exited {result.returncode}\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )

    if result.stdout:
        print(result.stdout.strip())

    return result.stdout


def copy_output(source, destination):
    if not source.is_file():
        raise FileNotFoundError(
            f"Expected output missing: {source}"
        )

    destination.parent.mkdir(
        parents=True, exist_ok=True
    )
    shutil.copyfile(source, destination)


def workspace_script(workspace, name):
    target = workspace / "analysis" / name
    target.parent.mkdir(parents=True, exist_ok=True)

    source = ANALYSIS / name
    if not source.is_file():
        raise FileNotFoundError(source)

    shutil.copyfile(source, target)
    return target


def link_evidence(workspace, scenarios=None):
    target = workspace / "experiments/evaluation"
    target.mkdir(parents=True, exist_ok=True)

    if scenarios is None:
        scenarios = [
            p.name for p in EVALUATION.iterdir()
            if p.is_dir()
        ]

    for scenario in scenarios:
        source = EVALUATION / scenario
        if not source.is_dir():
            continue

        (target / scenario).symlink_to(
            source,
            target_is_directory=True
        )


def scenario_d_e(destination):
    with tempfile.TemporaryDirectory(
        prefix="fa-de-"
    ) as tmp:
        workspace = Path(tmp)
        script = workspace_script(
            workspace,
            "collect-scenario-d-e-results.py"
        )

        link_evidence(
            workspace,
            ["scenario-d", "scenario-e"]
        )

        execute(script, [], workspace)

        copy_output(
            workspace / "analysis/results/"
            "new-experiment-d-e-results.csv",
            destination / "scenario-d-e-results.csv"
        )


def openmrs_clinical(destination):
    temp = destination / "openmrs-stage"
    temp.mkdir(parents=True, exist_ok=True)

    execute(
        ANALYSIS / "analyze-openmrs-clinical.py",
        [
            "--base",
            EVALUATION / "openmrs",
            "--output",
            temp,
        ],
        ROOT,
    )

    copy_output(
        temp / "clinical-metrics.csv",
        destination / "openmrs-clinical-metrics.csv"
    )


def openmrs_fencing(destination):
    temp = destination / "openmrs-stage"
    temp.mkdir(parents=True, exist_ok=True)

    execute(
        ANALYSIS / "analyze-openmrs-fencing.py",
        [
            "--base",
            EVALUATION / "openmrs",
            "--output",
            temp,
        ],
        ROOT,
    )

    copy_output(
        temp / "fencing-metrics.csv",
        destination / "openmrs-fencing-metrics.csv"
    )


def openmrs_phase2(destination):
    target = destination / "openmrs-phase2"

    execute(
        ANALYSIS / "analyze-openmrs-phase2.py",
        [
            "--base",
            EVALUATION / "openmrs",
            "--output",
            target,
        ],
        ROOT,
    )


def openmrs_statistics(destination):
    stage = destination / "openmrs-stage"

    # Statistics are calculated from freshly regenerated
    # clinical and fencing outputs, not historical summaries.
    required = [
        stage / "clinical-metrics.csv",
        stage / "fencing-metrics.csv",
    ]

    for path in required:
        if not path.is_file():
            raise FileNotFoundError(path)

    execute(
        ANALYSIS / "analyze-openmrs-statistics.py",
        ["--input", stage],
        ROOT,
    )

    copy_output(
        stage / "grouped-summary.csv",
        destination / "openmrs-grouped-statistics.csv"
    )


def controller_overhead(destination):
    source = HISTORICAL / "controller_overhead.csv"

    if not source.is_file():
        raise FileNotFoundError(source)

    with tempfile.TemporaryDirectory(
        prefix="fa-overhead-"
    ) as tmp:
        work = Path(tmp)

        run_output = work / "runs.csv"
        summary_output = work / "summary.csv"

        execute(
            ANALYSIS / "analyze-overhead.py",
            [
                source,
                "--run-output", run_output,
                "--output", summary_output,
            ],
            ROOT,
        )

        copy_output(
            run_output,
            destination / "controller-overhead-runs.csv"
        )
        copy_output(
            summary_output,
            destination / "controller-overhead-summary.csv"
        )


def http_latency(destination):
    with tempfile.TemporaryDirectory(
        prefix="fa-http-latency-"
    ) as tmp:
        workspace = Path(tmp)

        script = workspace_script(
            workspace,
            "analyze-http-latency.py"
        )

        evaluation = (
            workspace / "experiments/evaluation"
        )

        evaluation.mkdir(
            parents=True,
            exist_ok=True
        )

        source_files = sorted(
            EVALUATION.rglob("http-observations.csv")
        )

        if not source_files:
            raise RuntimeError(
                "No HTTP observation files found"
            )

        # Recreate actual directory structure.
        # Link all three files required for phase classification.
        required_files = (
            "http-observations.csv",
            "fault-time.txt",
            "fault-clear-time.txt",
        )

        for source in source_files:
            relative = source.parent.relative_to(
                EVALUATION
            )

            target_directory = evaluation / relative

            target_directory.mkdir(
                parents=True,
                exist_ok=True
            )

            for filename in required_files:
                original = source.parent / filename
                target = target_directory / filename

                if original.is_file():
                    target.symlink_to(original)

        results = workspace / "analysis/results"
        results.mkdir(
            parents=True,
            exist_ok=True
        )

        # Preserve the historical run population for
        # comparison with historical latency statistics.
        source_metrics = (
            HISTORICAL / "run-metrics.csv"
        )

        if not source_metrics.is_file():
            raise FileNotFoundError(source_metrics)

        shutil.copyfile(
            source_metrics,
            results / "run-metrics.csv"
        )

        execute(script, [], workspace)

        outputs = [
            (
                "http_latency_observations.csv",
                "http-latency-observations.csv",
            ),
            (
                "http_latency_by_run.csv",
                "http-latency-by-run.csv",
            ),
            (
                "http_latency_summary.csv",
                "http-latency-summary.csv",
            ),
        ]

        for source_name, destination_name in outputs:
            generated = results / source_name

            if not generated.is_file():
                raise RuntimeError(
                    f"HTTP output missing: {generated}"
                )

            rows = read_csv(generated)

            if not rows:
                raise RuntimeError(
                    f"HTTP output empty: {source_name}"
                )

            copy_output(
                generated,
                destination / destination_name
            )

        print(
            "HTTP_LATENCY_SOURCE_FILES:",
            len(source_files)
        )

        print(
            "HTTP_LATENCY_PHASE_INPUTS_RESTORED"
        )


def compare_historical(current, historical):
    if not historical.is_file():
        return "NO_HISTORICAL_REFERENCE"

    old = read_csv(historical)
    new = read_csv(current)

    if old == new:
        return "MATCH"

    return "DIFFERENT"


def validate_outputs(destination, stage):
    records = []
    missing = []

    for name in ARTIFACTS[stage]:
        path = destination / name

        if not path.is_file():
            missing.append(name)
            continue

        rows = read_csv(path)
        historical_name = HISTORICAL_NAMES.get(name)

        reference = (
            HISTORICAL / historical_name
            if historical_name else None
        )

        comparison = (
            compare_historical(path, reference)
            if reference
            else "NO_HISTORICAL_REFERENCE"
        )

        records.append({
            "stage": stage,
            "output": name,
            "rows": len(rows),
            "sha256": digest(path),
            "historical_reference": (
                historical_name or ""
            ),
            "comparison": comparison,
        })

    if missing:
        raise RuntimeError(
            "Missing outputs: " + ", ".join(missing)
        )

    return records


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT
    )

    args = parser.parse_args()
    destination = args.output.resolve()

    if destination != OUTPUT.resolve():
        parser.error(
            "Output must be analysis/results/reproduced"
        )

    if destination.is_symlink():
        parser.error("Output cannot be a symlink")

    destination.mkdir(parents=True, exist_ok=True)

    operations = [
        ("scenario_d_e", scenario_d_e),
        ("openmrs_clinical", openmrs_clinical),
        ("openmrs_fencing", openmrs_fencing),
        ("openmrs_phase2", openmrs_phase2),
        ("openmrs_statistics", openmrs_statistics),
        ("controller_overhead", controller_overhead),
        ("http_latency", http_latency),
    ]

    results = []
    failures = []

    for name, operation in operations:
        print()
        print("=" * 60)
        print("STAGE:", name)
        print("=" * 60)

        try:
            operation(destination)
            records = validate_outputs(
                destination, name
            )
            results.extend(records)
            print(name, "PASS")

        except Exception as exc:
            failures.append({
                "stage": name,
                "error": str(exc),
            })
            print(name, "FAIL:", exc)

    write_csv(
        destination / "manuscript-analysis-manifest.csv",
        results,
        MANIFEST_FIELDS,
    )

    report = {
        "status": "PASS" if not failures else "FAIL",
        "completed_stages": [
            name for name, _ in operations
            if name not in {
                item["stage"] for item in failures
            }
        ],
        "failures": failures,
        "historical_comparisons": {
            row["output"]: row["comparison"]
            for row in results
        },
        "experiments_executed": False,
    }

    with (
        destination / "manuscript-analysis-report.json"
    ).open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    # Temporary intermediate files are regenerated on demand.
    # They are kept until all stages are complete so that
    # failed stages can be investigated.

    print()
    print("MANUSCRIPT_ANALYSIS_STATUS:", report["status"])
    print("Completed:", len(report["completed_stages"]))
    print("Failed:", len(failures))
    print("No experiments executed.")

    if failures:
        return 1

    print("MANUSCRIPT_ANALYSES_EXECUTED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
