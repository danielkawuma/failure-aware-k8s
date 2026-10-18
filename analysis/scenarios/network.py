
#!/usr/bin/env python3
"""
Failure-Aware Kubernetes
Network baseline results reproduction.

Reads recorded ping and iperf3 output files.
Does not execute network measurements.

Output:
analysis/results/reproduced/network-baseline.csv
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DEFAULT_BASE = ROOT / "experiments/baseline/network"
DEFAULT_OUTPUT = (
    ROOT / "analysis/results/reproduced/network-baseline.csv"
)

MISSING = "NOT_RECORDED"

FIELDS = [
    "test_type",
    "source",
    "destination",
    "tool",
    "test_date",
    "configured_duration_s",
    "observed_duration_s",
    "configured_rate_mbps",
    "packets_sent",
    "packets_received",
    "rtt_min_ms",
    "rtt_median_ms",
    "rtt_mean_ms",
    "rtt_max_ms",
    "rtt_mdev_ms",
    "packet_loss_pct",
    "sender_throughput_mbps",
    "receiver_throughput_mbps",
    "sender_retransmissions",
    "udp_jitter_ms",
    "udp_datagrams_lost",
    "udp_datagrams_total",
    "udp_loss_pct",
    "source_file",
    "source_sha256",
]

PING_STATS = re.compile(
    r"(\d+)\s+packets transmitted,\s*"
    r"(\d+)\s+received,\s*"
    r"([\d.]+)%\s+packet loss"
)

PING_RTT = re.compile(
    r"rtt min/avg/max/mdev\s*=\s*"
    r"([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)"
)

IPERF_LINE = re.compile(
    r"^\[\s*\d+\]\s+"
    r"([\d.]+)-([\d.]+)\s+sec\s+"
    r"([\d.]+)\s+([KMG]?Bytes)\s+"
    r"([\d.]+)\s+([KMG]?bits/sec)\s+"
    r"(.*)$"
)

UDP_LOSS = re.compile(
    r"(\d+)/(\d+)\s+\(([\d.]+)%\)"
)

CONFIG_DURATION = re.compile(
    r"(?:^|\s)-t\s+(\d+)(?:\s|$)"
)

CONFIG_RATE = re.compile(
    r"(?:^|\s)-b\s+([\d.]+)([KMG])(?:\s|$)"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


def numeric(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return MISSING


def bitrate_mbps(value: str, unit: str):
    factor = {
        "bits/sec": 0.000001,
        "Kbits/sec": 0.001,
        "Mbits/sec": 1.0,
        "Gbits/sec": 1000.0,
    }

    return round(float(value) * factor[unit], 6)


def empty_row(path: Path, test_type: str):
    stem = path.stem

    if "-to-" in stem:
        source, destination = stem.split("-to-", 1)
    else:
        source, destination = MISSING, MISSING

    names = {
        "client": "Laptop",
        "server": "K3s server",
        "worker1": "Worker1",
        "worker2": "Worker2",
        "worker3": "Worker3",
        "worker4": "Worker4",
    }

    row = {field: MISSING for field in FIELDS}

    row.update({
        "test_type": test_type,
        "source": names.get(source, source),
        "destination": names.get(destination, destination),
        "tool": "ping" if test_type == "ping" else "iperf3",
        "source_file": path.relative_to(ROOT).as_posix(),
        "source_sha256": sha256(path),
    })

    return row


def parse_command(text: str, row: dict):
    for line in text.splitlines():
        if not line.startswith("# Command:"):
            continue

        command = line.split(":", 1)[1].strip()

        duration = CONFIG_DURATION.search(command)

        if duration:
            row["configured_duration_s"] = int(
                duration.group(1)
            )

        rate = CONFIG_RATE.search(command)

        if rate:
            value = float(rate.group(1))
            unit = rate.group(2)

            multiplier = {
                "K": 0.001,
                "M": 1,
                "G": 1000,
            }

            row["configured_rate_mbps"] = (
                value * multiplier[unit]
            )

        break


def parse_ping(path: Path):
    text = path.read_text(
        encoding="utf-8",
        errors="replace",
    )

    row = empty_row(path, "ping")

    match = PING_STATS.search(text)

    if match:
        row["packets_sent"] = int(match.group(1))
        row["packets_received"] = int(match.group(2))
        row["packet_loss_pct"] = numeric(match.group(3))

    match = PING_RTT.search(text)

    if match:
        row["rtt_min_ms"] = numeric(match.group(1))
        row["rtt_mean_ms"] = numeric(match.group(2))
        row["rtt_max_ms"] = numeric(match.group(3))
        row["rtt_mdev_ms"] = numeric(match.group(4))

    return row


def parse_iperf(path: Path, test_type: str):
    text = path.read_text(
        encoding="utf-8",
        errors="replace",
    )

    row = empty_row(path, test_type)

    parse_command(text, row)

    for line in text.splitlines():
        match = IPERF_LINE.match(line.strip())

        if not match:
            continue

        start, end, transfer, transfer_unit, bitrate, unit, rest = (
            match.groups()
        )

        if not (
            rest.rstrip().endswith("sender")
            or rest.rstrip().endswith("receiver")
        ):
            continue

        role = rest.split()[-1]

        throughput = bitrate_mbps(bitrate, unit)

        if role == "sender":
            row["sender_throughput_mbps"] = throughput

            if test_type == "tcp":
                tokens = rest.split()

                if len(tokens) >= 2:
                    try:
                        row["sender_retransmissions"] = int(
                            tokens[0]
                        )
                    except ValueError:
                        pass

        elif role == "receiver":
            row["receiver_throughput_mbps"] = throughput
            row["observed_duration_s"] = round(
                float(end) - float(start),
                3,
            )

            if test_type == "udp":
                tokens = rest.split()

                if len(tokens) >= 2:
                    row["udp_jitter_ms"] = numeric(tokens[0])

                loss = UDP_LOSS.search(rest)

                if loss:
                    row["udp_datagrams_lost"] = int(
                        loss.group(1)
                    )
                    row["udp_datagrams_total"] = int(
                        loss.group(2)
                    )
                    row["udp_loss_pct"] = numeric(
                        loss.group(3)
                    )

    return row


def write_csv(path: Path, rows):
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
            fieldnames=FIELDS,
        )

        writer.writeheader()
        writer.writerows(rows)


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

    args = parser.parse_args()

    base = args.base.resolve()
    output = args.output.resolve()

    if not base.is_dir():
        parser.error(
            f"Network baseline directory not found: {base}"
        )

    if base == output or base in output.parents:
        parser.error(
            "Output cannot be inside raw network evidence"
        )

    rows = []

    for test_type in ("ping", "tcp", "udp"):
        directory = base / test_type

        if not directory.is_dir():
            parser.error(
                f"Missing test directory: {directory}"
            )

        for path in sorted(directory.glob("*.txt")):
            if test_type == "ping":
                row = parse_ping(path)
            else:
                row = parse_iperf(path, test_type)

            rows.append(row)

    write_csv(output, rows)

    print("NETWORK_BASELINE_REPRODUCED")
    print("Records:", len(rows))
    print("Output:", output)

    for test_type in ("ping", "tcp", "udp"):
        count = sum(
            row["test_type"] == test_type
            for row in rows
        )

        print(f"{test_type.upper()}: {count}")


if __name__ == "__main__":
    main()
