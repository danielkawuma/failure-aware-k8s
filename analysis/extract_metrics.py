from __future__ import annotations

import csv
import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[1]

EVALUATION_ROOT = (
    REPO_ROOT
    / "experiments"
    / "evaluation"
)

OUTPUT_DIR = (
    REPO_ROOT
    / "analysis"
    / "results"
)

OUTPUT_FILE = (
    OUTPUT_DIR
    / "run-metrics.csv"
)


@dataclass
class RunMetrics:
    scenario: str
    mode: str
    run: str

    valid: bool
    invalid_reason: str

    fault_time: Optional[str]
    suspicion_time: Optional[str]
    decision_time: Optional[str]

    replacement_pending_time: Optional[str]
    replacement_running_time: Optional[str]

    service_restored_time: Optional[str]
    fault_clear_time: Optional[str]

    suspicion_delay_s: Optional[float]
    decision_delay_s: Optional[float]
    recovery_release_delay_s: Optional[float]
    replacement_pending_delay_s: Optional[float]
    replacement_running_delay_s: Optional[float]
    service_recovery_s: Optional[float]
    http_outage_s: Optional[float]

    original_pod: Optional[str]
    replacement_pod: Optional[str]

    original_node: Optional[str]
    replacement_node: Optional[str]

    replacement_occurred: Optional[bool]
    decision: Optional[str]

    first_http_failure_time: Optional[str]
    first_http_success_after_failure_time: Optional[str]

    recovery_release_time: Optional[str]


def parse_timestamp(
    value: Optional[str],
) -> Optional[datetime]:
    if not value:
        return None

    value = value.strip()

    if not value or value == "TIMEOUT":
        return None

    try:
        return datetime.fromisoformat(
            value.replace(
                "Z",
                "+00:00",
            )
        )
    except ValueError:
        return None


def format_timestamp(
    value: Optional[datetime],
) -> Optional[str]:
    if value is None:
        return None

    return value.isoformat()


def duration_seconds(
    start: Optional[datetime],
    end: Optional[datetime],
) -> Optional[float]:
    if start is None or end is None:
        return None

    return (
        end - start
    ).total_seconds()


def read_text(
    path: Path,
) -> Optional[str]:
    if not path.exists():
        return None

    content = path.read_text().strip()

    if not content:
        return None

    return content


def read_json(
    path: Path,
) -> dict:
    if not path.exists():
        return {}

    with path.open(
        "r",
        encoding="utf-8",
    ) as handle:
        return json.load(handle)


def read_csv(
    path: Path,
) -> list[dict]:
    if not path.exists():
        return []

    with path.open(
        "r",
        encoding="utf-8",
        newline="",
    ) as handle:
        return list(
            csv.DictReader(handle)
        )


def extract_controller_times(
    path: Path,
) -> dict:
    result = {
        "suspicion_time": None,
        "decision_time": None,
        "decision": None,
        "recovery_release_time": None,
    }

    if not path.exists():
        return result

    suspicion_re = re.compile(
        r"\[SUSPICION\]\s+"
        r"([^\s]+)"
    )

    decision_re = re.compile(
        r"\[DECISION\]\s+"
        r"([^\s]+).*?"
        r"decision=([A-Za-z]+)"
    )

    release_re = re.compile(
        r"\[RECOVERY RELEASE\]\s+"
        r"([^\s]+)"
    )

    with path.open(
        "r",
        encoding="utf-8",
        errors="replace",
    ) as handle:
        for line in handle:
            if (
                result["suspicion_time"]
                is None
            ):
                match = (
                    suspicion_re.search(
                        line
                    )
                )

                if match:
                    result[
                        "suspicion_time"
                    ] = (
                        match.group(1)
                    )

            if (
                result["decision_time"]
                is None
            ):
                match = (
                    decision_re.search(
                        line
                    )
                )

                if match:
                    result[
                        "decision_time"
                    ] = (
                        match.group(1)
                    )

                    result[
                        "decision"
                    ] = (
                        match.group(2)
                    )

            if (
                result[
                    "recovery_release_time"
                ]
                is None
            ):
                match = (
                    release_re.search(
                        line
                    )
                )

                if match:
                    result[
                        "recovery_release_time"
                    ] = (
                        match.group(1)
                    )

    return result


def extract_http_metrics(
    path: Path,
) -> dict:
    rows = read_csv(path)

    first_failure = None
    first_success_after_failure = None

    failure_seen = False

    for row in rows:
        timestamp = parse_timestamp(
            row.get("timestamp_utc")
        )

        success = (
            row.get(
                "success",
                "",
            )
            .strip()
            .lower()
            == "true"
        )

        if (
            not success
            and not failure_seen
        ):
            failure_seen = True
            first_failure = timestamp

        elif (
            failure_seen
            and success
            and first_success_after_failure
            is None
        ):
            first_success_after_failure = (
                timestamp
            )

    outage = duration_seconds(
        first_failure,
        first_success_after_failure,
    )

    return {
        "first_http_failure_time":
            format_timestamp(
                first_failure
            ),

        "first_http_success_after_failure_time":
            format_timestamp(
                first_success_after_failure
            ),

        "http_outage_s":
            outage,
    }


def extract_pod_metrics(
    path: Path,
    original_pod: Optional[str],
) -> dict:
    rows = read_csv(path)

    replacement_pod = None
    replacement_node = None

    replacement_pending_time = None
    replacement_running_time = None

    seen_candidates = set()

    for row in rows:
        pod = (
            row.get(
                "pod",
                "",
            )
            .strip()
        )

        if not pod:
            continue

        if (
            original_pod
            and pod == original_pod
        ):
            continue

        if pod in seen_candidates:
            candidate_known = True
        else:
            candidate_known = False
            seen_candidates.add(pod)

        phase = (
            row.get(
                "phase",
                "",
            )
            .strip()
        )

        node = (
            row.get(
                "node",
                "",
            )
            .strip()
        )

        deletion = (
            row.get(
                "deletion_timestamp",
                "",
            )
            .strip()
        )

        timestamp = parse_timestamp(
            row.get("timestamp_utc")
        )

        if deletion:
            continue

        if (
            phase == "Pending"
            and replacement_pending_time
            is None
        ):
            replacement_pending_time = (
                timestamp
            )

            replacement_pod = pod

            if node:
                replacement_node = node

        if phase == "Running":
            if (
                replacement_pod is None
                or replacement_pod == pod
                or not candidate_known
            ):
                replacement_pod = pod

                if node:
                    replacement_node = node

                if (
                    replacement_running_time
                    is None
                ):
                    replacement_running_time = (
                        timestamp
                    )

    return {
        "replacement_pod":
            replacement_pod,

        "replacement_node":
            replacement_node,

        "replacement_pending_time":
            format_timestamp(
                replacement_pending_time
            ),

        "replacement_running_time":
            format_timestamp(
                replacement_running_time
            ),

        "replacement_occurred":
            replacement_pod
            is not None,
    }


def validate_run(
    scenario: str,
    mode: str,
    run_dir: Path,
    replacement_occurred: Optional[bool],
    service_restored: Optional[datetime],
) -> tuple[bool, str]:
    reasons = []

    if not (
        run_dir
        / "COMPLETE"
    ).exists():
        reasons.append(
            "COMPLETE marker missing"
        )

    if not (
        run_dir
        / "experiment-metadata.json"
    ).exists():
        reasons.append(
            "experiment metadata missing"
        )

    if not (
        run_dir
        / "http-observations.csv"
    ).exists():
        reasons.append(
            "HTTP observations missing"
        )

    if not (
        run_dir
        / "pod-observations.csv"
    ).exists():
        reasons.append(
            "Pod observations missing"
        )

    if scenario == "scenario-c":
        if not replacement_occurred:
            reasons.append(
                "replacement Pod not observed"
            )

        if service_restored is None:
            reasons.append(
                "service restoration not observed"
            )

    if (
        mode == "failure-aware"
        and not (
            run_dir
            / "controller.log"
        ).exists()
    ):
        reasons.append(
            "controller log missing"
        )

    if reasons:
        return (
            False,
            "; ".join(reasons),
        )

    return (
        True,
        "",
    )


def extract_run(
    scenario: str,
    mode: str,
    run_dir: Path,
) -> RunMetrics:
    metadata = read_json(
        run_dir
        / "experiment-metadata.json"
    )

    original_pod = (
        metadata.get(
            "original_pod"
        )
    )

    original_node = (
        metadata.get(
            "original_node"
        )
    )

    fault_time_raw = read_text(
        run_dir
        / "fault-time.txt"
    )

    fault_clear_raw = read_text(
        run_dir
        / "fault-clear-time.txt"
    )

    service_restored_raw = read_text(
        run_dir
        / "service-restored-time.txt"
    )

    fault_time = parse_timestamp(
        fault_time_raw
    )

    fault_clear_time = parse_timestamp(
        fault_clear_raw
    )

    service_restored_time = (
        parse_timestamp(
            service_restored_raw
        )
    )

    controller = extract_controller_times(
        run_dir
        / "controller.log"
    )

    suspicion_time = parse_timestamp(
        controller[
            "suspicion_time"
        ]
    )

    decision_time = parse_timestamp(
        controller[
            "decision_time"
        ]
    )

    recovery_release_time = (
        parse_timestamp(
            controller[
                "recovery_release_time"
            ]
        )
    )

    pod_metrics = extract_pod_metrics(
        run_dir
        / "pod-observations.csv",
        original_pod,
    )

    replacement_pending_time = (
        parse_timestamp(
            pod_metrics[
                "replacement_pending_time"
            ]
        )
    )

    replacement_running_time = (
        parse_timestamp(
            pod_metrics[
                "replacement_running_time"
            ]
        )
    )

    http_metrics = extract_http_metrics(
        run_dir
        / "http-observations.csv"
    )

    valid, invalid_reason = (
        validate_run(
            scenario,
            mode,
            run_dir,
            pod_metrics[
                "replacement_occurred"
            ],
            service_restored_time,
        )
    )

    return RunMetrics(
        scenario=scenario,
        mode=mode,
        run=run_dir.name,

        valid=valid,
        invalid_reason=invalid_reason,

        fault_time=format_timestamp(
            fault_time
        ),

        suspicion_time=format_timestamp(
            suspicion_time
        ),

        decision_time=format_timestamp(
            decision_time
        ),

        replacement_pending_time=
            format_timestamp(
                replacement_pending_time
            ),

        replacement_running_time=
            format_timestamp(
                replacement_running_time
            ),

        service_restored_time=
            format_timestamp(
                service_restored_time
            ),

        fault_clear_time=
            format_timestamp(
                fault_clear_time
            ),

        suspicion_delay_s=
            duration_seconds(
                fault_time,
                suspicion_time,
            ),

        decision_delay_s=
            duration_seconds(
                suspicion_time,
                decision_time,
            ),

        recovery_release_delay_s=
            duration_seconds(
                decision_time,
                recovery_release_time,
            ),

        replacement_pending_delay_s=
            duration_seconds(
                fault_time,
                replacement_pending_time,
            ),

        replacement_running_delay_s=
            duration_seconds(
                fault_time,
                replacement_running_time,
            ),

        service_recovery_s=
            duration_seconds(
                fault_time,
                service_restored_time,
            ),

        http_outage_s=
            http_metrics[
                "http_outage_s"
            ],

        original_pod=original_pod,

        replacement_pod=
            pod_metrics[
                "replacement_pod"
            ],

        original_node=original_node,

        replacement_node=
            pod_metrics[
                "replacement_node"
            ],

        replacement_occurred=
            pod_metrics[
                "replacement_occurred"
            ],

        decision=
            controller[
                "decision"
            ],

        first_http_failure_time=
            http_metrics[
                "first_http_failure_time"
            ],

        first_http_success_after_failure_time=
            http_metrics[
                "first_http_success_after_failure_time"
            ],

        recovery_release_time=
            format_timestamp(
                recovery_release_time
            ),
    )


def discover_runs() -> list[
    tuple[
        str,
        str,
        Path,
    ]
]:
    runs = []

    for scenario_dir in sorted(
        EVALUATION_ROOT.glob(
            "scenario-*"
        )
    ):
        if not scenario_dir.is_dir():
            continue

        scenario = scenario_dir.name

        for mode in (
            "native",
            "failure-aware",
        ):
            mode_dir = (
                scenario_dir
                / mode
            )

            if not mode_dir.exists():
                continue

            for run_dir in sorted(
                mode_dir.glob(
                    "run-*"
                )
            ):
                if not run_dir.is_dir():
                    continue

                if (
                    "invalid"
                    in run_dir.name
                ):
                    continue

                runs.append(
                    (
                        scenario,
                        mode,
                        run_dir,
                    )
                )

    return runs


def write_metrics(
    metrics: list[RunMetrics],
) -> None:
    OUTPUT_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    fieldnames = list(
        RunMetrics.__dataclass_fields__
        .keys()
    )

    with OUTPUT_FILE.open(
        "w",
        encoding="utf-8",
        newline="",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fieldnames,
        )

        writer.writeheader()

        for metric in metrics:
            writer.writerow(
                metric.__dict__
            )


def main() -> None:
    runs = discover_runs()

    print(
        f"Discovered {len(runs)} experiment runs"
    )

    metrics = []

    for (
        scenario,
        mode,
        run_dir,
    ) in runs:
        print(
            f"Extracting "
            f"{scenario}/"
            f"{mode}/"
            f"{run_dir.name}"
        )

        metric = extract_run(
            scenario,
            mode,
            run_dir,
        )

        metrics.append(
            metric
        )

        status = (
            "VALID"
            if metric.valid
            else "INVALID"
        )

        print(
            f"  -> {status}"
        )

        if not metric.valid:
            print(
                f"     {metric.invalid_reason}"
            )

    write_metrics(
        metrics
    )

    valid_count = sum(
        1
        for item in metrics
        if item.valid
    )

    invalid_count = (
        len(metrics)
        - valid_count
    )

    print()
    print(
        f"Valid runs   : {valid_count}"
    )

    print(
        f"Invalid runs : {invalid_count}"
    )

    print(
        f"Metrics written to:"
    )

    print(
        OUTPUT_FILE
    )


if __name__ == "__main__":
    main()