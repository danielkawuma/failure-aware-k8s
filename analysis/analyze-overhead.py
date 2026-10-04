#!/usr/bin/env python3

import argparse
import csv
import datetime as dt
import math
import statistics
from collections import defaultdict
from pathlib import Path


METRICS = {
    "controller_cpu_mean_millicores": "millicores",
    "controller_cpu_p95_millicores": "millicores",
    "controller_rss_mean_mib": "MiB",
    "controller_rss_p95_mib": "MiB",
    "host_rx_bytes_per_second": "bytes/s",
    "host_tx_bytes_per_second": "bytes/s",
}


def parse_timestamp(value):
    return dt.datetime.fromisoformat(
        value.replace("Z", "+00:00")
    ).timestamp()


def percentile(values, probability):
    if not values:
        return 0.0

    ordered = sorted(values)

    if len(ordered) == 1:
        return ordered[0]

    position = probability * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)

    if lower == upper:
        return ordered[lower]

    fraction = position - lower

    return (
        ordered[lower]
        + fraction * (ordered[upper] - ordered[lower])
    )


def t_critical_95(sample_count):
    critical_values = {
        2: 12.706,
        3: 4.303,
        4: 3.182,
        5: 2.776,
        6: 2.571,
        7: 2.447,
        8: 2.365,
        9: 2.306,
        10: 2.262,
        11: 2.228,
        12: 2.201,
        13: 2.179,
        14: 2.160,
        15: 2.145,
        16: 2.131,
        17: 2.120,
        18: 2.110,
        19: 2.101,
        20: 2.093,
        21: 2.086,
        22: 2.080,
        23: 2.074,
        24: 2.069,
        25: 2.064,
        26: 2.060,
        27: 2.056,
        28: 2.052,
        29: 2.048,
        30: 2.045,
    }

    if sample_count <= 1:
        return 0.0

    return critical_values.get(sample_count, 1.96)


def describe(values):
    count = len(values)

    if count == 0:
        return {
            "n": 0,
            "mean": "",
            "stddev": "",
            "ci95_low": "",
            "ci95_high": "",
        }

    mean = statistics.fmean(values)

    if count == 1:
        stddev = 0.0
        half_width = 0.0
    else:
        stddev = statistics.stdev(values)
        half_width = (
            t_critical_95(count)
            * stddev
            / math.sqrt(count)
        )

    return {
        "n": count,
        "mean": mean,
        "stddev": stddev,
        "ci95_low": mean - half_width,
        "ci95_high": mean + half_width,
    }


def load_raw(path):
    groups = defaultdict(list)

    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            key = (
                row["run_id"],
                row["mode"],
                row["phase"],
            )

            groups[key].append(
                {
                    "timestamp": parse_timestamp(row["timestamp"]),
                    "cpu": float(row["cpu_millicores"]),
                    "rss": float(row["rss_mib"]),
                    "rx": int(row["rx_bytes"]),
                    "tx": int(row["tx_bytes"]),
                }
            )

    return groups


def summarise_runs(groups):
    results = []

    for (run_id, mode, phase), samples in sorted(groups.items()):
        samples.sort(key=lambda item: item["timestamp"])

        cpu_values = [item["cpu"] for item in samples]
        rss_values = [item["rss"] for item in samples]

        # The first process CPU sample is necessarily zero because
        # no preceding process-tick observation exists.
        if mode == "failure-aware" and len(cpu_values) > 1:
            cpu_values = cpu_values[1:]

        elapsed = 0.0
        received = 0
        transmitted = 0

        if len(samples) >= 2:
            elapsed = (
                samples[-1]["timestamp"]
                - samples[0]["timestamp"]
            )

            received = max(
                0,
                samples[-1]["rx"] - samples[0]["rx"],
            )

            transmitted = max(
                0,
                samples[-1]["tx"] - samples[0]["tx"],
            )

        rx_rate = received / elapsed if elapsed > 0 else 0.0
        tx_rate = transmitted / elapsed if elapsed > 0 else 0.0

        results.append(
            {
                "run_id": run_id,
                "mode": mode,
                "phase": phase,
                "samples": len(samples),
                "controller_cpu_mean_millicores":
                    statistics.fmean(cpu_values),
                "controller_cpu_p95_millicores":
                    percentile(cpu_values, 0.95),
                "controller_rss_mean_mib":
                    statistics.fmean(rss_values),
                "controller_rss_p95_mib":
                    percentile(rss_values, 0.95),
                "host_rx_bytes_per_second": rx_rate,
                "host_tx_bytes_per_second": tx_rate,
            }
        )

    return results


def write_run_results(path, rows):
    fields = [
        "run_id",
        "mode",
        "phase",
        "samples",
        *METRICS.keys(),
    ]

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def build_summary(rows):
    by_mode = defaultdict(lambda: defaultdict(list))
    by_run = defaultdict(dict)

    for row in rows:
        mode = row["mode"]
        run_id = row["run_id"]

        by_run[run_id][mode] = row

        for metric in METRICS:
            by_mode[mode][metric].append(float(row[metric]))

    summary = []

    for metric, unit in METRICS.items():
        native_values = by_mode["native"][metric]
        aware_values = by_mode["failure-aware"][metric]

        native = describe(native_values)
        aware = describe(aware_values)

        paired_differences = []

        for run_id, modes in by_run.items():
            if "native" not in modes or "failure-aware" not in modes:
                continue

            paired_differences.append(
                float(modes["failure-aware"][metric])
                - float(modes["native"][metric])
            )

        difference = describe(paired_differences)

        percent_change = ""

        if native["mean"] != "" and native["mean"] != 0:
            percent_change = (
                (aware["mean"] - native["mean"])
                / native["mean"]
                * 100
            )

        summary.append(
            {
                "metric": metric,
                "unit": unit,
                "native_n": native["n"],
                "native_mean": native["mean"],
                "native_stddev": native["stddev"],
                "native_ci95_low": native["ci95_low"],
                "native_ci95_high": native["ci95_high"],
                "failure_aware_n": aware["n"],
                "failure_aware_mean": aware["mean"],
                "failure_aware_stddev": aware["stddev"],
                "failure_aware_ci95_low": aware["ci95_low"],
                "failure_aware_ci95_high": aware["ci95_high"],
                "paired_n": difference["n"],
                "mean_absolute_overhead": difference["mean"],
                "overhead_ci95_low": difference["ci95_low"],
                "overhead_ci95_high": difference["ci95_high"],
                "percent_change": percent_change,
            }
        )

    return summary


def write_summary(path, rows):
    fields = [
        "metric",
        "unit",
        "native_n",
        "native_mean",
        "native_stddev",
        "native_ci95_low",
        "native_ci95_high",
        "failure_aware_n",
        "failure_aware_mean",
        "failure_aware_stddev",
        "failure_aware_ci95_low",
        "failure_aware_ci95_high",
        "paired_n",
        "mean_absolute_overhead",
        "overhead_ci95_low",
        "overhead_ci95_high",
        "percent_change",
    ]

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("input")
    parser.add_argument("--run-output", required=True)
    parser.add_argument("--output", required=True)

    args = parser.parse_args()

    input_path = Path(args.input)
    run_output = Path(args.run_output)
    summary_output = Path(args.output)

    for output in (run_output, summary_output):
        if output.exists():
            raise SystemExit(
                f"Refusing to overwrite existing result: {output}"
            )

        output.parent.mkdir(parents=True, exist_ok=True)

    groups = load_raw(input_path)
    run_results = summarise_runs(groups)

    write_run_results(run_output, run_results)
    write_summary(summary_output, build_summary(run_results))

    print(f"Per-run results: {run_output}")
    print(f"Summary results: {summary_output}")


if __name__ == "__main__":
    main()