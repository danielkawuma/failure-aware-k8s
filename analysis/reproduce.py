
#!/usr/bin/env python3
"""
Failure-Aware Kubernetes: results-only reproduction.

Current validated stages:
  1. Evidence inventory and SHA-256 integrity manifest.
  2. Network baseline reproduction.
  3. OpenMRS Scenario C recovery reproduction.
  4. Historical recovery-reference comparison.

All source evidence is read-only.
All generated outputs are placed under:
  analysis/results/reproduced/

No Kubernetes, SSH, fault injection, controller execution,
harness execution, or experimental campaign is performed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

OUTPUT = ROOT / "analysis/results/reproduced"

EVIDENCE_ROOTS = [
    ROOT / "experiments/baseline",
    ROOT / "experiments/evaluation",
    ROOT / "results",
    ROOT / "analysis/results",
]

EXCLUDED_DIRS = {
    ".git",
    "__pycache__",
    "target",
    "reproduced",
}

MARKERS = (
    "COMPLETE",
    "INCOMPLETE",
    "BLOCKED",
)

MANIFEST_FIELDS = [
    "source_file",
    "category",
    "size_bytes",
    "sha256",
]

SCHEMA_FIELDS = [
    "source_file",
    "rows",
    "columns",
    "column_names",
    "sha256",
]

RUN_FIELDS = [
    "scenario",
    "mode",
    "run",
    "status",
    "source_directory",
]


def utc_now():
    return datetime.now(
        timezone.utc
    ).isoformat(timespec="milliseconds")


def relative(path):
    return path.relative_to(ROOT).as_posix()


def sha256_file(path):
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


def excluded(path, output):
    if path == output or output in path.parents:
        return True

    return any(
        part in EXCLUDED_DIRS
        for part in path.relative_to(ROOT).parts
    )


def evidence_files(output):
    seen = set()

    for root in EVIDENCE_ROOTS:
        if not root.exists():
            continue

        for directory, dirs, files in os.walk(root):
            current = Path(directory)

            dirs[:] = [
                name for name in dirs
                if not excluded(current / name, output)
            ]

            for name in files:
                path = current / name

                if path.is_symlink() or not path.is_file():
                    continue

                if excluded(path, output):
                    continue

                resolved = path.resolve()

                if resolved in seen:
                    continue

                seen.add(resolved)
                yield path


def category(path):
    name = relative(path)

    if name.startswith("experiments/baseline/"):
        return "baseline_evidence"

    if name.startswith("experiments/evaluation/"):
        return "experimental_evidence"

    if name.startswith("analysis/results/"):
        return "historical_analysis"

    if name.startswith("results/"):
        return "supplementary_results"

    return "other"


def inspect_csv(path, digest):
    with path.open(
        newline="",
        encoding="utf-8-sig",
    ) as handle:
        reader = csv.reader(handle)
        header = next(reader, [])
        count = sum(1 for _ in reader)

    return {
        "source_file": relative(path),
        "rows": count,
        "columns": len(header),
        "column_names": "|".join(header),
        "sha256": digest,
    }


def discover_runs():
    base = ROOT / "experiments/evaluation"
    rows = []

    if not base.exists():
        return rows

    for directory, dirs, _ in os.walk(base):
        current = Path(directory)

        dirs[:] = [
            name for name in dirs
            if name not in EXCLUDED_DIRS
        ]

        if not current.name.startswith("run-"):
            continue

        markers = [
            marker for marker in MARKERS
            if (current / marker).is_file()
        ]

        if len(markers) > 1:
            status = "CONFLICTING_MARKERS"
        elif markers:
            status = markers[0]
        else:
            status = "NO_STATUS_MARKER"

        parts = current.relative_to(base).parts

        rows.append({
            "scenario": parts[0],
            "mode": "/".join(parts[1:-1]),
            "run": current.name,
            "status": status,
            "source_directory": relative(current),
        })

    return sorted(
        rows,
        key=lambda row: row["source_directory"],
    )


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
            extrasaction="ignore",
        )
        writer.writeheader()
        writer.writerows(rows)


def validate_output(output):
    output = output.resolve()
    expected = OUTPUT.resolve()

    if output != expected:
        raise ValueError(
            "This version only writes to "
            "analysis/results/reproduced/"
        )

    if output.is_symlink():
        raise ValueError(
            "Reproduction output must not be a symlink"
        )

    if any(
        part.is_symlink()
        for part in [
            output.parent,
            output.parent.parent,
        ]
    ):
        raise ValueError(
            "Reproduction output parent must not be a symlink"
        )


def integrity_stage(output):
    manifest = []
    schemas = []
    errors = []

    for path in sorted(evidence_files(output)):
        try:
            digest = sha256_file(path)

            manifest.append({
                "source_file": relative(path),
                "category": category(path),
                "size_bytes": path.stat().st_size,
                "sha256": digest,
            })

            if path.suffix.lower() == ".csv":
                schemas.append(
                    inspect_csv(path, digest)
                )

        except (OSError, UnicodeError, csv.Error) as exc:
            errors.append({
                "source_file": relative(path),
                "error": str(exc),
            })

    runs = discover_runs()

    write_csv(
        output / "evidence-manifest.csv",
        manifest,
        MANIFEST_FIELDS,
    )

    write_csv(
        output / "csv-schemas.csv",
        schemas,
        SCHEMA_FIELDS,
    )

    write_csv(
        output / "run-inventory.csv",
        runs,
        RUN_FIELDS,
    )

    return {
        "status": "PASS" if not errors else "FAIL",
        "evidence_files": len(manifest),
        "csv_files": len(schemas),
        "run_directories": len(runs),
        "complete_runs": sum(
            r["status"] == "COMPLETE"
            for r in runs
        ),
        "incomplete_runs": sum(
            r["status"] == "INCOMPLETE"
            for r in runs
        ),
        "errors": errors,
    }


def execute_stage(name, script, arguments):
    command = [
        sys.executable,
        str(script),
        *arguments,
    ]

    print()
    print("=" * 60)
    print("STAGE:", name)
    print("=" * 60)

    if not script.is_file():
        return {
            "status": "FAIL",
            "error": f"Missing analysis script: {script}",
        }

    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        stdin=subprocess.DEVNULL,
    )

    if result.stdout:
        print(result.stdout, end="")

    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")

    return {
        "status": (
            "PASS" if result.returncode == 0
            else "FAIL"
        ),
        "exit_code": result.returncode,
        "script": relative(script),
        "command_arguments": arguments,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }


def git_revision():
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        stdin=subprocess.DEVNULL,
    )

    return (
        result.stdout.strip()
        if result.returncode == 0
        else "NOT_RECORDED"
    )


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Regenerate Failure-Aware Kubernetes research "
            "results from existing evidence."
        )
    )

    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT,
    )

    args = parser.parse_args()
    output = args.output.resolve()

    validate_output(output)

    output.mkdir(
        parents=True,
        exist_ok=True,
    )

    started = utc_now()

    print("FAILURE-AWARE RESULTS REPRODUCTION")
    print("Started:", started)
    print("Git revision:", git_revision())
    print("Output:", output)

    stages = {}

    print()
    print("=== EVIDENCE INTEGRITY ===")

    stages["evidence_integrity"] = integrity_stage(
        output
    )

    print(
        "Evidence files:",
        stages["evidence_integrity"]["evidence_files"],
    )

    print(
        "CSV files:",
        stages["evidence_integrity"]["csv_files"],
    )

    print(
        "Run directories:",
        stages["evidence_integrity"]["run_directories"],
    )

    stages["network_baseline"] = execute_stage(
        "Network baseline",
        ROOT / "analysis/scenarios/network.py",
        [
            "--output",
            str(output / "network-baseline.csv"),
        ],
    )

    reference = (
        ROOT / "analysis/reference/"
        "openmrs-scenario-c-recovery-durations.csv"
    )

    stages["openmrs_scenario_c_recovery"] = execute_stage(
        "OpenMRS Scenario C recovery",
        ROOT / "analysis/scenarios/openmrs_recovery.py",
        [
            "--output",
            str(
                output
                / "openmrs-scenario-c-recovery-durations.csv"
            ),
            "--reference",
            str(reference),
        ],
    )

    stages["scenario_a"] = execute_stage(
        "Scenario A genuine node-loss analysis",
        ROOT / "analysis/scenarios/scenario_a.py",
        [
            "--output",
            str(output),
        ],
    )

    passed = all(
        stage["status"] == "PASS"
        for stage in stages.values()
    )

    report = {
        "pipeline": "failure-aware-results-reproduction",
        "pipeline_version": "stage-2",
        "started_utc": started,
        "completed_utc": utc_now(),
        "git_revision": git_revision(),
        "overall_status": (
            "PASS" if passed else "FAIL"
        ),
        "raw_evidence_modified": False,
        "experiments_executed": False,
        "stages": stages,
        "pending_analysis": [
            "nginx_scenarios_b_c",
            "scenario_a_final",
            "scenario_d_e",
            "openmrs_clinical",
            "openmrs_fencing",
            "controller_overhead",
            "historical_manuscript_cohort_validation",
        ],
    }

    report_path = (
        output / "validation-report.json"
    )

    with report_path.open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            report,
            handle,
            indent=2,
        )
        handle.write("\n")

    print()
    print("=" * 60)
    print("REPRODUCTION SUMMARY")
    print("=" * 60)

    for name, stage in stages.items():
        print(
            f"{name}: {stage['status']}"
        )

    print()
    print(
        "Overall:",
        report["overall_status"],
    )
    print("Validation report:", report_path)
    print("No experiments executed.")

    if not passed:
        print("REPRODUCTION_STAGE_FAILED")
        return 1

    print("REPRODUCTION_STAGE_2_PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
