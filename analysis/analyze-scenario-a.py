#!/usr/bin/env python3

import csv
import json
import re
import statistics
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "experiments/evaluation/scenario-a"
OUTPUT = ROOT / "analysis/results/scenario-a"

OUTPUT.mkdir(parents=True, exist_ok=True)


def timestamp(value):
    if not value:
        return None

    try:
        return datetime.fromisoformat(
            value.strip().replace("Z", "+00:00")
        )
    except ValueError:
        return None


def duration(start, end):
    if start is None or end is None:
        return None

    return round((end - start).total_seconds(), 3)


def read_time(path):
    if not path.exists():
        return None
    return timestamp(path.read_text().strip())


def read_csv(path):
    if not path.exists():
        return []

    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def first_transition(rows):
    failure = None
    restored = None

    for row in rows:
        t = timestamp(row.get("timestamp_utc"))

        if t is None:
            continue

        success = (
            row.get("success", "").strip().lower() == "true"
        )

        if not success and failure is None:
            failure = t
        elif failure is not None and success:
            restored = t
            break

    return failure, restored


def first_node_unknown(rows):
    for row in rows:
        if row.get("ready_status") == "Unknown":
            return timestamp(row.get("timestamp_utc"))
    return None


def controller_decision(path):
    result = {
        "decision_time": None,
        "decision": "",
        "candidate": "",
        "attempts": None,
        "successes": None,
    }

    if not path.exists():
        return result

    text = path.read_text(errors="replace")

    verification = re.search(
        r"\[VERIFICATION\].*?"
        r"attempts=(\d+).*?"
        r"successes=(\d+)",
        text,
    )

    if verification:
        result["attempts"] = int(verification.group(1))
        result["successes"] = int(verification.group(2))

    decision = re.search(
        r"\[DECISION\]\s+(\S+).*?"
        r"decision=(\w+).*?"
        r"selected_candidate=Some\(\"([^\"]+)\"\)",
        text,
    )

    if decision:
        result["decision_time"] = timestamp(decision.group(1))
        result["decision"] = decision.group(2)
        result["candidate"] = decision.group(3)

    return result


def original_identity(directory):
    path = directory / "pods-before.json"

    if not path.exists():
        return "", ""

    data = json.loads(path.read_text())
    pods = data.get("items", [])

    if len(pods) != 1:
        return "", ""

    return (
        pods[0]["metadata"]["name"],
        pods[0]["metadata"]["uid"],
    )


def recovery_result(directory):
    path = directory / "recovery-outcome.json"

    if not path.exists():
        return {}

    return json.loads(path.read_text())


def replacement_observations(rows, original, arm):
    observations = []

    for row in rows:
        pod = row.get("pod", "")
        node = row.get("node", "")
        phase = row.get("phase", "")
        deletion = row.get("deletion_timestamp", "")

        if not pod or pod == original:
            continue

        if not node or node == "k3s-worker1":
            continue

        if arm == "failure-aware" and node != "k3s-worker2":
            continue

        if deletion:
            continue

        t = timestamp(row.get("timestamp_utc"))

        if t is None:
            continue

        observations.append({
            "pod": pod,
            "node": node,
            "phase": phase,
            "time": t,
        })

    return observations


def replacement_times(observations, selected_name):
    if not selected_name:
        return None, None

    pending = [
        r["time"] for r in observations
        if r["pod"] == selected_name
        and r["phase"] == "Pending"
    ]

    running = [
        r["time"] for r in observations
        if r["pod"] == selected_name
        and r["phase"] == "Running"
    ]

    return (
        min(pending) if pending else None,
        min(running) if running else None,
    )


def collect():
    results = []

    for arm in ("native", "failure-aware"):
        for directory in sorted((BASE / arm).glob("run-*")):
            if not directory.is_dir():
                continue

            stop = read_time(directory / "vm-stop-requested.txt")
            ping_loss = read_time(
                directory / "vm-ping-loss-confirmed.txt"
            )
            hold_end = read_time(
                directory / "hold-completed.txt"
            )
            ping_return = read_time(
                directory / "vm-ping-returned.txt"
            )
            ssh_return = read_time(
                directory / "vm-ssh-returned.txt"
            )
            node_return = read_time(
                directory / "worker1-ready-returned.txt"
            )

            nodes = read_csv(directory / "node-observations.csv")
            pods = read_csv(directory / "pod-observations.csv")
            http = read_csv(directory / "http-observations.csv")
            standalone = read_csv(
                directory / "single-node-http.csv"
            )

            unknown = first_node_unknown(nodes)
            decision = controller_decision(
                directory / "controller.log"
            )

            original_name, original_uid = original_identity(
                directory
            )

            recovery = recovery_result(directory)

            selected_name = recovery.get("replacement_pod")
            selected_node = recovery.get("replacement_node")

            observations = replacement_observations(
                pods, original_name, arm
            )

            pending, running = replacement_times(
                observations, selected_name
            )

            k_fail, k_success = first_transition(http)
            s_fail, s_success = first_transition(standalone)

            complete = (directory / "COMPLETE").exists()

            reason_path = directory / "failure-reason.txt"
            reason = (
                reason_path.read_text().strip()
                if reason_path.exists()
                else ""
            )

            results.append({
                "arm": arm,
                "run": directory.name,
                "status": "COMPLETE" if complete else "INCOMPLETE",
                "reason": reason,
                "recovery_outcome": recovery.get(
                    "outcome", "not recorded"
                ),
                "stop_requested_utc": stop,
                "shutoff_confirmed_utc": "not recorded",
                "ping_loss_utc": ping_loss,
                "hold_completed_utc": hold_end,
                "vm_start_requested_utc": "not recorded",
                "ping_returned_utc": ping_return,
                "ssh_returned_utc": ssh_return,
                "worker_ready_returned_utc": node_return,
                "ready_unknown_utc": unknown,
                "verification_attempts": decision["attempts"],
                "verification_successes": decision["successes"],
                "decision": decision["decision"],
                "selected_candidate": decision["candidate"],
                "decision_time_utc": decision["decision_time"],
                "replacement_pod": selected_name,
                "replacement_node": selected_node,
                "replacement_pending_utc": pending,
                "replacement_running_utc": running,
                "k3s_first_failure_utc": k_fail,
                "k3s_first_success_utc": k_success,
                "single_first_failure_utc": s_fail,
                "single_first_success_utc": s_success,
                "suspicion_delay_s": duration(stop, unknown),
                "decision_delay_s": duration(
                    unknown, decision["decision_time"]
                ),
                "replacement_running_s": duration(stop, running),
                "k3s_http_outage_s": duration(k_fail, k_success),
                "single_http_outage_s": duration(s_fail, s_success),
            })

    return results


def write_csv(path, rows):
    if not rows:
        return

    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f, fieldnames=list(rows[0])
        )
        writer.writeheader()

        for row in rows:
            writer.writerow({
                k: (
                    v.isoformat().replace("+00:00", "Z")
                    if isinstance(v, datetime)
                    else "not recorded"
                    if v is None or v == ""
                    else v
                )
                for k, v in row.items()
            })


def summarize(rows):
    metrics = [
        "suspicion_delay_s",
        "decision_delay_s",
        "replacement_running_s",
        "k3s_http_outage_s",
        "single_http_outage_s",
    ]

    summary = []

    for arm in ("native", "failure-aware"):
        completed = [
            row for row in rows
            if row["arm"] == arm
            and row["status"] == "COMPLETE"
        ]

        for metric in metrics:
            values = [
                row[metric]
                for row in completed
                if isinstance(row[metric], (int, float))
            ]

            summary.append({
                "arm": arm,
                "metric": metric,
                "n": len(values),
                "mean": statistics.mean(values) if values else None,
                "sd": statistics.stdev(values) if len(values) > 1 else None,
                "median": statistics.median(values) if values else None,
                "min": min(values) if values else None,
                "max": max(values) if values else None,
            })

    return summary


def main():
    rows = collect()

    write_csv(OUTPUT / "run-metrics.csv", rows)
    write_csv(OUTPUT / "summary.csv", summarize(rows))

    print("Scenario A analysis complete")
    print("Attempted runs:", len(rows))
    print(
        "Completed runs:",
        sum(r["status"] == "COMPLETE" for r in rows)
    )
    print("Output:", OUTPUT)


if __name__ == "__main__":
    main()