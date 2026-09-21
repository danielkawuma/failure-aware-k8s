from __future__ import annotations

import csv
import math
from collections import defaultdict
from pathlib import Path
from statistics import mean, stdev


REPO_ROOT = Path(__file__).resolve().parents[1]

RESULTS_DIR = (
    REPO_ROOT
    / "analysis"
    / "results"
)

INPUT_FILE = (
    RESULTS_DIR
    / "run-metrics.csv"
)

OUTPUT_FILE = (
    RESULTS_DIR
    / "summary.csv"
)


NUMERIC_METRICS = [
    "suspicion_delay_s",
    "decision_delay_s",
    "recovery_release_delay_s",
    "replacement_pending_delay_s",
    "replacement_running_delay_s",
    "service_recovery_s",
    "http_outage_s",
]


#
# Student's t critical values for
# two-sided 95% confidence intervals.
#
# For n > 30, 1.96 is a sufficiently
# close normal approximation for this
# experimental analysis.
#
T_95 = {
    1: None,
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


def read_rows() -> list[dict]:
    if not INPUT_FILE.exists():
        raise FileNotFoundError(
            f"Missing input file: {INPUT_FILE}"
        )

    with INPUT_FILE.open(
        "r",
        encoding="utf-8",
        newline="",
    ) as handle:
        return list(
            csv.DictReader(handle)
        )


def parse_bool(
    value: str,
) -> bool:
    return (
        value.strip()
        .lower()
        == "true"
    )


def parse_float(
    value: str,
) -> float | None:
    value = value.strip()

    if not value:
        return None

    try:
        return float(value)
    except ValueError:
        return None


def t_critical_95(
    n: int,
) -> float | None:
    if n < 2:
        return None

    if n <= 30:
        return T_95[n]

    return 1.96


def summarize_values(
    values: list[float],
) -> dict:
    n = len(values)

    if n == 0:
        return {
            "n": 0,
            "mean": "",
            "stddev": "",
            "ci95_low": "",
            "ci95_high": "",
            "ci95_half_width": "",
            "min": "",
            "max": "",
        }

    average = mean(values)

    minimum = min(values)
    maximum = max(values)

    if n == 1:
        return {
            "n": 1,
            "mean": average,
            "stddev": "",
            "ci95_low": "",
            "ci95_high": "",
            "ci95_half_width": "",
            "min": minimum,
            "max": maximum,
        }

    sd = stdev(values)

    t_value = t_critical_95(
        n
    )

    standard_error = (
        sd
        / math.sqrt(n)
    )

    half_width = (
        t_value
        * standard_error
    )

    return {
        "n": n,
        "mean": average,
        "stddev": sd,
        "ci95_low":
            average - half_width,
        "ci95_high":
            average + half_width,
        "ci95_half_width":
            half_width,
        "min": minimum,
        "max": maximum,
    }


def main() -> None:
    rows = read_rows()

    valid_rows = [
        row
        for row in rows
        if parse_bool(
            row.get(
                "valid",
                "false",
            )
        )
    ]

    grouped = defaultdict(list)

    for row in valid_rows:
        key = (
            row["scenario"],
            row["mode"],
        )

        grouped[key].append(
            row
        )

    RESULTS_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    output_rows = []

    for (
        scenario,
        mode,
    ), group_rows in sorted(
        grouped.items()
    ):
        total_runs = len(
            group_rows
        )

        replacement_count = sum(
            1
            for row in group_rows
            if parse_bool(
                row.get(
                    "replacement_occurred",
                    "false",
                )
            )
        )

        decisions = defaultdict(int)

        for row in group_rows:
            decision = (
                row.get(
                    "decision",
                    ""
                )
                .strip()
            )

            if decision:
                decisions[
                    decision
                ] += 1

        for metric in NUMERIC_METRICS:
            values = []

            for row in group_rows:
                value = parse_float(
                    row.get(
                        metric,
                        "",
                    )
                )

                if value is not None:
                    values.append(
                        value
                    )

            summary = summarize_values(
                values
            )

            output_rows.append(
                {
                    "scenario":
                        scenario,

                    "mode":
                        mode,

                    "metric":
                        metric,

                    "valid_runs":
                        total_runs,

                    "n":
                        summary[
                            "n"
                        ],

                    "mean":
                        summary[
                            "mean"
                        ],

                    "stddev":
                        summary[
                            "stddev"
                        ],

                    "ci95_low":
                        summary[
                            "ci95_low"
                        ],

                    "ci95_high":
                        summary[
                            "ci95_high"
                        ],

                    "ci95_half_width":
                        summary[
                            "ci95_half_width"
                        ],

                    "min":
                        summary[
                            "min"
                        ],

                    "max":
                        summary[
                            "max"
                        ],

                    "replacement_count":
                        replacement_count,

                    "replacement_rate":
                        (
                            replacement_count
                            / total_runs
                            if total_runs
                            else ""
                        ),

                    "preserve_decisions":
                        decisions.get(
                            "Preserve",
                            0,
                        ),

                    "recover_decisions":
                        decisions.get(
                            "Recover",
                            0,
                        ),
                }
            )

    fieldnames = [
        "scenario",
        "mode",
        "metric",
        "valid_runs",
        "n",
        "mean",
        "stddev",
        "ci95_low",
        "ci95_high",
        "ci95_half_width",
        "min",
        "max",
        "replacement_count",
        "replacement_rate",
        "preserve_decisions",
        "recover_decisions",
    ]

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

        writer.writerows(
            output_rows
        )

    print(
        f"Summary written to:"
    )

    print(
        OUTPUT_FILE
    )

    print()

    for (
        scenario,
        mode,
    ), group_rows in sorted(
        grouped.items()
    ):
        print(
            f"{scenario} / {mode}"
        )

        print(
            f"  valid runs: "
            f"{len(group_rows)}"
        )

        for metric in (
            "service_recovery_s",
            "http_outage_s",
            "replacement_running_delay_s",
        ):
            values = [
                value
                for row in group_rows
                if (
                    value := parse_float(
                        row.get(
                            metric,
                            "",
                        )
                    )
                )
                is not None
            ]

            summary = (
                summarize_values(
                    values
                )
            )

            if summary["n"] == 0:
                continue

            print(
                f"  {metric}: "
                f"mean={summary['mean']:.3f}s"
            )

            if (
                summary[
                    "ci95_half_width"
                ]
                != ""
            ):
                print(
                    f"    95% CI: "
                    f"{summary['mean']:.3f} "
                    f"+/- "
                    f"{summary['ci95_half_width']:.3f}s"
                )

        print()


if __name__ == "__main__":
    main()