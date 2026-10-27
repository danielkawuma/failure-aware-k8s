#!/usr/bin/env python3

import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "experiments/evaluation/openmrs/concurrent-writer"

OUTPUT = ROOT / "analysis/results/concurrent-writer-summary.csv"

FIELDS = [
    "mode",
    "run",
    "old_writer_commits_after_transfer",
    "replacement_commits_after_transfer",
    "overlap_duration_s",
    "fence_verified",
    "old_writer_rejections",
    "database_integrity",
    "evidence_status",
]


def main():
    rows = []

    for mode in ("unfenced", "fenced"):
        directory = BASE / mode

        if not directory.exists():
            continue

        for run in sorted(directory.glob("run-*")):
            if not run.is_dir():
                continue

            # Never infer success from the existence of
            # a run directory or a controller decision.
            rows.append({
                "mode": mode,
                "run": run.name,
                "old_writer_commits_after_transfer": "",
                "replacement_commits_after_transfer": "",
                "overlap_duration_s": "",
                "fence_verified": "",
                "old_writer_rejections": "",
                "database_integrity": "",
                "evidence_status": "NOT_MEASURED",
            })

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    with OUTPUT.open(
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

    print("CONCURRENT_WRITER_ANALYSIS_PREPARED")
    print("Runs discovered:", len(rows))
    print("Output:", OUTPUT)
    print("No unverified measurements inferred.")


if __name__ == "__main__":
    main()
