#!/usr/bin/env python3

import csv
import json
import math
import re
from datetime import datetime
from pathlib import Path
from statistics import mean


REPO_ROOT = Path(__file__).resolve().parents[1]

SCENARIO_D_ROOT = (
    REPO_ROOT
    / "experiments"
    / "evaluation"
    / "scenario-d"
    / "failure-aware"
)

SCENARIO_E_ROOT = (
    REPO_ROOT
    / "experiments"
    / "evaluation"
    / "scenario-e"
    / "failure-aware"
)

OUTPUT_FILE = (
    REPO_ROOT
    / "analysis"
    / "results"
    / "new-experiment-d-e-results.csv"
)


FIELDNAMES = [
    "scenario",
    "profile",
    "run_number",
    "run_directory",
    "complete",
    "correct_outcome",

    "decision",
    "node_unknown_observed",
    "original_pod_present",
    "replacement_count",

    "delay_ms",
    "jitter_ms",
    "packet_loss_percent",
    "rate_mbit",
    "fault_duration_s",

    "verification_attempts",
    "verification_successes",
    "verification_failures",
    "verification_latency_mean_ms",
    "verification_latency_p95_ms",
    "verification_latency_max_ms",
    "suspicion_to_decision_s",
    "node_unknown_duration_s",

    "http_requests",
    "http_successes",
    "http_failures",
    "http_success_rate_percent",
    "http_latency_mean_ms",
    "http_latency_p95_ms",
    "http_latency_p99_ms",

    "pre_fence_marker_count",
    "post_fence_marker_count",
    "recovery_marker_count",
    "post_unfence_marker_count",

    "old_authority_stopped_before_fence",
    "worker1_nfs_access_blocked_before_recovery",
    "old_authority_active_after_unfence",

    "authority_stop_s",
    "fence_to_recovery_release_s",
    "recovery_release_to_service_s",
    "fence_to_service_s",
]


def empty_row():
    return {field: "" for field in FIELDNAMES}


def read_text(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return ""


def read_json(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}


def read_integer(path):
    value = read_text(path)

    if not value:
        return None

    try:
        return int(value)
    except ValueError:
        return None


def parse_timestamp(value):
    if not value:
        return None

    value = value.strip()

    # Reduce nanosecond timestamps to Python-supported microseconds.
    value = re.sub(
        r"(\.\d{6})\d+(?=(?:Z|[+-]\d{2}:\d{2})?$)",
        r"\1",
        value,
    )

    if value.endswith("Z"):
        value = value[:-1] + "+00:00"

    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def read_timestamp(path):
    return parse_timestamp(read_text(path))


def seconds_between(start, end):
    if start is None or end is None:
        return ""

    return round((end - start).total_seconds(), 6)


def percentile(values, percentile_value):
    if not values:
        return ""

    ordered = sorted(values)

    if len(ordered) == 1:
        return round(ordered[0], 6)

    position = (len(ordered) - 1) * percentile_value
    lower_index = math.floor(position)
    upper_index = math.ceil(position)

    if lower_index == upper_index:
        return round(ordered[lower_index], 6)

    lower_value = ordered[lower_index]
    upper_value = ordered[upper_index]
    fraction = position - lower_index

    result = lower_value + (
        upper_value - lower_value
    ) * fraction

    return round(result, 6)


def parse_run_number(run_directory):
    match = re.fullmatch(
        r"run-(\d+)",
        run_directory.name,
    )

    if not match:
        return None

    return int(match.group(1))


def bool_text(value):
    if value is True:
        return "true"

    if value is False:
        return "false"

    return ""


def find_http_observation_file(run_directory):
    candidate_names = {
        "http-observations.csv",
        "http_observations.csv",
    }

    for path in run_directory.rglob("*.csv"):
        if path.name in candidate_names:
            return path

    return None


def parse_boolean(value):
    return str(value).strip().lower() in {
        "true",
        "1",
        "yes",
        "success",
    }


def summarize_http_fault_window(
    run_directory,
    fault_time,
    clear_time,
):
    summary = {
        "http_requests": "",
        "http_successes": "",
        "http_failures": "",
        "http_success_rate_percent": "",
        "http_latency_mean_ms": "",
        "http_latency_p95_ms": "",
        "http_latency_p99_ms": "",
    }

    observation_file = find_http_observation_file(
        run_directory
    )

    if (
        observation_file is None
        or fault_time is None
        or clear_time is None
    ):
        return summary

    requests = 0
    successes = 0
    failures = 0
    successful_latencies = []

    try:
        with observation_file.open(
            "r",
            encoding="utf-8",
            newline="",
        ) as handle:
            reader = csv.DictReader(handle)

            for record in reader:
                timestamp = parse_timestamp(
                    record.get("timestamp_utc", "")
                )

                if timestamp is None:
                    continue

                if not (
                    fault_time
                    <= timestamp
                    <= clear_time
                ):
                    continue

                requests += 1

                success = parse_boolean(
                    record.get("success", "")
                )

                if success:
                    successes += 1

                    try:
                        successful_latencies.append(
                            float(
                                record.get(
                                    "latency_ms",
                                    "",
                                )
                            )
                        )
                    except ValueError:
                        pass
                else:
                    failures += 1

    except (OSError, csv.Error):
        return summary

    summary["http_requests"] = requests
    summary["http_successes"] = successes
    summary["http_failures"] = failures

    if requests:
        summary["http_success_rate_percent"] = round(
            successes / requests * 100,
            6,
        )

    if successful_latencies:
        summary["http_latency_mean_ms"] = round(
            mean(successful_latencies),
            6,
        )

        summary["http_latency_p95_ms"] = percentile(
            successful_latencies,
            0.95,
        )

        summary["http_latency_p99_ms"] = percentile(
            successful_latencies,
            0.99,
        )

    return summary


def parse_controller_log(path):
    result = {
        "decision": "",
        "verification_attempts": "",
        "verification_successes": "",
        "verification_failures": "",
        "verification_latency_mean_ms": "",
        "verification_latency_p95_ms": "",
        "verification_latency_max_ms": "",
        "suspicion_to_decision_s": "",
        "node_unknown_duration_s": "",
    }

    log_text = read_text(path)

    if not log_text:
        return result

    verification_latencies = []

    for match in re.finditer(
        r"\[VERIFY\].*?"
        r"attempt=(\d+)/(\d+).*?"
        r"reachable=(true|false).*?"
        r"latency=([0-9.]+)\s*ms",
        log_text,
        flags=re.IGNORECASE,
    ):
        verification_latencies.append(
            float(match.group(4))
        )

    awareness_match = re.search(
        r"\[AWARENESS\].*?"
        r"attempts=(\d+)\s*\|\s*"
        r"successes=(\d+)\s*\|\s*"
        r"failures=(\d+)",
        log_text,
        flags=re.IGNORECASE,
    )

    if awareness_match:
        result["verification_attempts"] = int(
            awareness_match.group(1)
        )

        result["verification_successes"] = int(
            awareness_match.group(2)
        )

        result["verification_failures"] = int(
            awareness_match.group(3)
        )
    elif verification_latencies:
        result["verification_attempts"] = len(
            verification_latencies
        )

    if verification_latencies:
        result["verification_latency_mean_ms"] = round(
            mean(verification_latencies),
            6,
        )

        result["verification_latency_p95_ms"] = percentile(
            verification_latencies,
            0.95,
        )

        result["verification_latency_max_ms"] = round(
            max(verification_latencies),
            6,
        )

    decision_match = re.search(
        r"\[DECISION\]\s+"
        r"([^|]+)\|.*?"
        r"decision=(Preserve|Recover)",
        log_text,
        flags=re.IGNORECASE,
    )

    if decision_match:
        result["decision"] = (
            decision_match.group(2).capitalize()
        )

        decision_time = parse_timestamp(
            decision_match.group(1).strip()
        )
    else:
        decision_time = None

    suspicion_match = re.search(
        r"\[SUSPICION\]\s+([^|]+)\|",
        log_text,
        flags=re.IGNORECASE,
    )

    if suspicion_match:
        suspicion_time = parse_timestamp(
            suspicion_match.group(1).strip()
        )
    else:
        suspicion_time = None

    recovered_match = re.search(
        r"\[RECOVERED\]\s+([^|]+)\|",
        log_text,
        flags=re.IGNORECASE,
    )

    if recovered_match:
        recovered_time = parse_timestamp(
            recovered_match.group(1).strip()
        )
    else:
        recovered_time = None

    result["suspicion_to_decision_s"] = (
        seconds_between(
            suspicion_time,
            decision_time,
        )
    )

    result["node_unknown_duration_s"] = (
        seconds_between(
            suspicion_time,
            recovered_time,
        )
    )

    return result


def collect_scenario_d():
    rows = []

    if not SCENARIO_D_ROOT.exists():
        return rows

    for run_directory in sorted(
        SCENARIO_D_ROOT.glob("run-*")
    ):
        run_number = parse_run_number(run_directory)

        if run_number is None or run_number < 200:
            continue

        if not (
            run_directory
            / "COMPLETE"
        ).is_file():
            continue

        metadata = read_json(
            run_directory
            / "experiment-metadata.json"
        )

        row = empty_row()

        row["scenario"] = "scenario-d"
        row["profile"] = "stateful-fencing"
        row["run_number"] = run_number
        row["run_directory"] = str(
            run_directory.relative_to(REPO_ROOT)
        )
        row["complete"] = "true"

        pre_fence_count = read_integer(
            run_directory
            / "pre-fence-marker-count.txt"
        )

        post_fence_count = read_integer(
            run_directory
            / "post-fence-marker-count.txt"
        )

        recovery_count = read_integer(
            run_directory
            / "recovery-marker-count.txt"
        )

        post_unfence_count = read_integer(
            run_directory
            / "post-unfence-marker-count.txt"
        )

        row["pre_fence_marker_count"] = (
            ""
            if pre_fence_count is None
            else pre_fence_count
        )

        row["post_fence_marker_count"] = (
            ""
            if post_fence_count is None
            else post_fence_count
        )

        row["recovery_marker_count"] = (
            ""
            if recovery_count is None
            else recovery_count
        )

        row["post_unfence_marker_count"] = (
            ""
            if post_unfence_count is None
            else post_unfence_count
        )

        old_stopped = metadata.get(
            "old_authority_stopped_before_fence"
        )

        nfs_blocked = metadata.get(
            "worker1_nfs_access_blocked_before_recovery"
        )

        row[
            "old_authority_stopped_before_fence"
        ] = bool_text(old_stopped)

        row[
            "worker1_nfs_access_blocked_before_recovery"
        ] = bool_text(nfs_blocked)

        old_containers_file = (
            run_directory
            / "old-containers-after-unfence.txt"
        )

        old_authority_active = bool(
            read_text(old_containers_file)
        )

        row[
            "old_authority_active_after_unfence"
        ] = bool_text(old_authority_active)

        stop_start = read_timestamp(
            run_directory
            / "old-authority-stop-start-time.txt"
        )

        old_stopped_time = read_timestamp(
            run_directory
            / "old-authority-stopped-time.txt"
        )

        fence_time = read_timestamp(
            run_directory
            / "fence-time.txt"
        )

        release_time = read_timestamp(
            run_directory
            / "recovery-release-time.txt"
        )

        restored_time = read_timestamp(
            run_directory
            / "service-restored-time.txt"
        )

        row["authority_stop_s"] = seconds_between(
            stop_start,
            old_stopped_time,
        )

        row[
            "fence_to_recovery_release_s"
        ] = seconds_between(
            fence_time,
            release_time,
        )

        row[
            "recovery_release_to_service_s"
        ] = seconds_between(
            release_time,
            restored_time,
        )

        row["fence_to_service_s"] = seconds_between(
            fence_time,
            restored_time,
        )

        correct = (
            pre_fence_count == 1
            and post_fence_count == 0
            and recovery_count == 1
            and post_unfence_count == 0
            and old_stopped is True
            and nfs_blocked is True
            and not old_authority_active
        )

        row["correct_outcome"] = bool_text(correct)

        rows.append(row)

    return rows


def collect_scenario_e():
    rows = []

    if not SCENARIO_E_ROOT.exists():
        return rows

    for profile_directory in sorted(
        SCENARIO_E_ROOT.iterdir()
    ):
        if not profile_directory.is_dir():
            continue

        profile = profile_directory.name

        for run_directory in sorted(
            profile_directory.glob("run-*")
        ):
            run_number = parse_run_number(
                run_directory
            )

            if run_number is None or run_number < 2:
                continue

            if not (
                run_directory
                / "COMPLETE"
            ).is_file():
                continue

            metadata = read_json(
                run_directory
                / "experiment-metadata.json"
            )

            outcome = read_json(
                run_directory
                / "scenario-e-outcome.json"
            )

            controller = parse_controller_log(
                run_directory
                / "controller.log"
            )

            row = empty_row()

            row["scenario"] = "scenario-e"
            row["profile"] = profile
            row["run_number"] = run_number
            row["run_directory"] = str(
                run_directory.relative_to(REPO_ROOT)
            )
            row["complete"] = "true"

            node_unknown = outcome.get(
                "node_unknown_observed"
            )

            original_present = outcome.get(
                "original_pod_present_after_degradation"
            )

            replacement_count = outcome.get(
                "replacement_count"
            )

            row["node_unknown_observed"] = bool_text(
                node_unknown
            )

            row["original_pod_present"] = bool_text(
                original_present
            )

            row["replacement_count"] = (
                ""
                if replacement_count is None
                else replacement_count
            )

            row["decision"] = controller["decision"]

            row["delay_ms"] = metadata.get(
                "delay_ms",
                "",
            )

            row["jitter_ms"] = metadata.get(
                "jitter_ms",
                "",
            )

            row["packet_loss_percent"] = metadata.get(
                "packet_loss_percent",
                "",
            )

            row["rate_mbit"] = metadata.get(
                "rate_mbit",
                "",
            )

            for key in [
                "verification_attempts",
                "verification_successes",
                "verification_failures",
                "verification_latency_mean_ms",
                "verification_latency_p95_ms",
                "verification_latency_max_ms",
                "suspicion_to_decision_s",
                "node_unknown_duration_s",
            ]:
                row[key] = controller[key]

            fault_time = read_timestamp(
                run_directory
                / "fault-time.txt"
            )

            clear_time = read_timestamp(
                run_directory
                / "fault-clear-time.txt"
            )

            row["fault_duration_s"] = seconds_between(
                fault_time,
                clear_time,
            )

            http_summary = summarize_http_fault_window(
                run_directory,
                fault_time,
                clear_time,
            )

            row.update(http_summary)

            correct = (
                replacement_count == 0
                and original_present is True
                and (
                    node_unknown is not True
                    or controller["decision"] == "Preserve"
                )
            )

            row["correct_outcome"] = bool_text(correct)

            rows.append(row)

    return rows


def main():
    rows = []

    rows.extend(collect_scenario_d())
    rows.extend(collect_scenario_e())

    rows.sort(
        key=lambda row: (
            row["scenario"],
            row["profile"],
            int(row["run_number"]),
        )
    )

    OUTPUT_FILE.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with OUTPUT_FILE.open(
        "w",
        encoding="utf-8",
        newline="",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=FIELDNAMES,
        )

        writer.writeheader()
        writer.writerows(rows)

    scenario_d_count = sum(
        row["scenario"] == "scenario-d"
        for row in rows
    )

    scenario_e_count = sum(
        row["scenario"] == "scenario-e"
        for row in rows
    )

    print(f"Scenario D rows: {scenario_d_count}")
    print(f"Scenario E rows: {scenario_e_count}")
    print(f"Total rows: {len(rows)}")
    print(f"Output: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()