
#!/usr/bin/env python3
"""
Failure-Aware Kubernetes: OpenMRS Scenario C recovery reproduction.

Produces:
  openmrs-scenario-c-recovery-durations.csv
  openmrs-scenario-c-replacement-observations.csv

Historical replacement readiness requires the dedicated
replacement-ready-observed-time.txt marker.

Supplementary replacement readiness is independently extracted
from recovery-observations.csv using the recorded replacement Pod.

All analysis is offline. Original records are read-only.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DEFAULT_BASE = (
    ROOT / "experiments/evaluation/openmrs/scenario-c"
)

DEFAULT_OUTPUT = (
    ROOT / "analysis/results/reproduced/"
    "openmrs-scenario-c-recovery-durations.csv"
)

MISSING = ""

FIELDS = [
    "mode",
    "run",
    "status",
    "fault_start",
    "fault_clear",
    "clinical_restored",
    "replacement_ready",
    "fault_duration_seconds",
    "fault_to_clinical_restoration_seconds",
    "fault_clear_to_clinical_restoration_seconds",
    "fault_to_replacement_ready_seconds",
    "source_directory",
]

OBS_FIELDS = [
    "mode",
    "run",
    "status",
    "original_pod",
    "replacement_pod",
    "explicit_replacement_ready",
    "observed_replacement_ready",
    "observed_fault_to_replacement_ready_seconds",
    "observation_source",
    "explicit_marker_present",
    "observation_agrees_with_marker",
    "source_directory",
]

TIME_PATTERN = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T"
    r"\d{2}:\d{2}:\d{2})"
    r"(?:\.(\d{1,9}))?"
    r"(Z|[+-]\d{2}:\d{2})$"
)


def timestamp_ns(value):
    match = TIME_PATTERN.fullmatch(value.strip())

    if not match:
        raise ValueError(
            f"Invalid timestamp: {value!r}"
        )

    whole, fraction, offset = match.groups()
    fraction = (fraction or "").ljust(9, "0")

    if offset == "Z":
        offset = "+00:00"

    dt = datetime.fromisoformat(
        whole + offset
    ).astimezone(timezone.utc)

    epoch = datetime(
        1970, 1, 1, tzinfo=timezone.utc
    )

    delta = dt - epoch

    return (
        (delta.days * 86400 + delta.seconds)
        * 1_000_000_000
        + int(fraction)
    )


def duration(start, end):
    if not start or not end:
        return MISSING

    value = Decimal(
        timestamp_ns(end) - timestamp_ns(start)
    ) / Decimal(1_000_000_000)

    return str(value.quantize(
        Decimal("0.001"),
        rounding=ROUND_HALF_UP,
    ))


def read_text(directory, name):
    path = directory / name

    if not path.is_file():
        return MISSING

    return path.read_text(
        encoding="utf-8"
    ).strip()


def read_timestamp(directory, *names):
    for name in names:
        value = read_text(directory, name)

        if value:
            timestamp_ns(value)
            return value

    return MISSING


def status(directory):
    markers = [
        marker
        for marker in (
            "COMPLETE",
            "INCOMPLETE",
            "BLOCKED",
        )
        if (directory / marker).is_file()
    ]

    if len(markers) > 1:
        return "CONFLICTING_MARKERS"

    return (
        markers[0]
        if markers
        else "NO_STATUS_MARKER"
    )


def original_pod(directory):
    metadata = read_text(
        directory, "metadata.env"
    )

    match = re.search(
        r"(?mi)^\s*original_pod\s*=\s*(.*?)\s*$",
        metadata,
    )

    if match:
        return match.group(1).strip("'\" ")

    return MISSING


def replacement_pod(directory):
    return read_text(
        directory, "replacement-pod.txt"
    )


def observed_ready(directory, original, replacement):
    path = directory / "recovery-observations.csv"

    if not path.is_file():
        return MISSING

    # A replacement must be independently identified.
    if not original or not replacement:
        return MISSING

    if original == replacement:
        return MISSING

    candidates = []

    with path.open(
        newline="",
        encoding="utf-8",
    ) as handle:
        reader = csv.DictReader(handle)

        required = {
            "utc", "pod", "phase", "ready"
        }

        if not required.issubset(
            reader.fieldnames or []
        ):
            raise ValueError(
                f"Invalid recovery CSV schema: {path}"
            )

        for row in reader:
            pod = (row.get("pod") or "").strip()
            phase = (row.get("phase") or "").strip()
            ready = (
                row.get("ready") or ""
            ).strip().lower()
            observed = (
                row.get("utc") or ""
            ).strip()

            if pod != replacement:
                continue

            if phase != "Running":
                continue

            if ready not in ("true", "1", "yes"):
                continue

            if not observed:
                continue

            candidates.append(
                (timestamp_ns(observed), observed)
            )

    if not candidates:
        return MISSING

    return min(candidates)[1]


def collect(base):
    historical = []
    supplementary = []

    for mode in ("V0", "T5", "T10", "T30", "FA1"):
        mode_dir = base / mode

        if not mode_dir.is_dir():
            continue

        for directory in sorted(
            mode_dir.glob("run-*")
        ):
            if not directory.is_dir():
                continue

            start = read_timestamp(
                directory,
                "fault-time.txt",
                "fault-start-time.txt",
            )

            clear = read_timestamp(
                directory,
                "fault-clear-time.txt",
            )

            clinical = read_timestamp(
                directory,
                "clinical-restored-observed-time.txt",
            )

            # Historical metric: dedicated marker only.
            explicit_ready = read_timestamp(
                directory,
                "replacement-ready-observed-time.txt",
            )

            original = original_pod(directory)
            replacement = replacement_pod(directory)

            observed = observed_ready(
                directory,
                original,
                replacement,
            )

            agreement = "NOT_APPLICABLE"

            if explicit_ready and observed:
                difference = abs(
                    timestamp_ns(explicit_ready)
                    - timestamp_ns(observed)
                )

                agreement = (
                    "YES"
                    if difference <= 1_000_000_000
                    else "NO"
                )

            source = directory.relative_to(
                ROOT
            ).as_posix()

            run_status = status(directory)

            historical.append({
                "mode": mode,
                "run": directory.name,
                "status": run_status,
                "fault_start": start,
                "fault_clear": clear,
                "clinical_restored": clinical,
                "replacement_ready": explicit_ready,
                "fault_duration_seconds":
                    duration(start, clear),
                "fault_to_clinical_restoration_seconds":
                    duration(start, clinical),
                "fault_clear_to_clinical_restoration_seconds":
                    duration(clear, clinical),
                "fault_to_replacement_ready_seconds":
                    duration(start, explicit_ready),
                "source_directory": source,
            })

            supplementary.append({
                "mode": mode,
                "run": directory.name,
                "status": run_status,
                "original_pod": original,
                "replacement_pod": replacement,
                "explicit_replacement_ready":
                    explicit_ready,
                "observed_replacement_ready":
                    observed,
                "observed_fault_to_replacement_ready_seconds":
                    duration(start, observed),
                "observation_source": (
                    (
                        source
                        + "/recovery-observations.csv"
                    )
                    if observed else MISSING
                ),
                "explicit_marker_present":
                    "YES" if explicit_ready else "NO",
                "observation_agrees_with_marker":
                    agreement,
                "source_directory": source,
            })

    return historical, supplementary


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


def compare_reference(rows, reference):
    with reference.open(
        newline="",
        encoding="utf-8",
    ) as handle:
        expected_rows = list(
            csv.DictReader(handle)
        )

    expected = {
        (r["mode"], r["run"]): r
        for r in expected_rows
    }

    actual = {
        (r["mode"], r["run"]): r
        for r in rows
    }

    errors = []

    if len(expected) != len(expected_rows):
        errors.append(
            "Duplicate run identifiers in reference"
        )

    if len(actual) != len(rows):
        errors.append(
            "Duplicate run identifiers in reproduced data"
        )

    for key in sorted(
        set(expected) | set(actual)
    ):
        if key not in expected:
            errors.append(f"Unexpected run: {key}")
            continue

        if key not in actual:
            errors.append(f"Missing run: {key}")
            continue

        left = expected[key]
        right = actual[key]

        for field in FIELDS:
            a = (left.get(field) or "").strip()
            b = (right.get(field) or "").strip()

            if field.endswith("_seconds"):
                if not a and not b:
                    continue

                if not a or not b:
                    errors.append(
                        f"{key} {field}: "
                        f"expected={a!r}, actual={b!r}"
                    )
                    continue

                if abs(
                    Decimal(a) - Decimal(b)
                ) > Decimal("0.001"):
                    errors.append(
                        f"{key} {field}: "
                        f"expected={a}, actual={b}"
                    )
            elif a != b:
                errors.append(
                    f"{key} {field}: "
                    f"expected={a!r}, actual={b!r}"
                )

    return errors


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--base",
        type=Path,
        default=DEFAULT_BASE,
    )

    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
    )

    parser.add_argument(
        "--reference",
        type=Path,
        default=None,
    )

    args = parser.parse_args()

    base = args.base.resolve()
    output = args.output.resolve()

    if not base.is_dir():
        parser.error(
            f"Evidence directory missing: {base}"
        )

    if base == output or base in output.parents:
        parser.error(
            "Output cannot be inside raw evidence"
        )

    historical, supplementary = collect(base)

    supplementary_output = (
        output.parent
        / "openmrs-scenario-c-replacement-observations.csv"
    )

    write_csv(
        output,
        historical,
        FIELDS,
    )

    write_csv(
        supplementary_output,
        supplementary,
        OBS_FIELDS,
    )

    print(
        "OPENMRS_SCENARIO_C_RECOVERY_REPRODUCED"
    )
    print("Historical records:", len(historical))
    print("Supplementary records:", len(supplementary))
    print("Historical output:", output)
    print("Supplementary output:", supplementary_output)

    disagreements = [
        row for row in supplementary
        if row["observation_agrees_with_marker"] == "NO"
    ]

    if disagreements:
        for row in disagreements:
            print(
                "READINESS_DISAGREEMENT:",
                row["mode"],
                row["run"],
            )

        return 1

    if args.reference:
        reference = args.reference.resolve()

        if not reference.is_file():
            parser.error(
                f"Reference not found: {reference}"
            )

        errors = compare_reference(
            historical,
            reference,
        )

        if errors:
            print("REFERENCE_COMPARISON_FAILED")

            for error in errors:
                print("MISMATCH:", error)

            return 1

        print("REFERENCE_COMPARISON_PASSED")

    return 0


if __name__ == "__main__":
    sys.exit(main())
