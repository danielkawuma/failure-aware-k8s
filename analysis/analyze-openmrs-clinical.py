#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path
from datetime import datetime

def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None

def observations(path):
    if not path.is_file():
        return []

    samples = {}
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            t = row.get("utc", "")
            if not t or ts(t) is None:
                continue

            ok = row.get("clinical_ok", "").lower() == "true"
            if t in samples and samples[t] != ok:
                raise ValueError(f"Conflicting clinical status at {t}")
            samples[t] = ok

    return sorted(
        ((ts(k), v) for k, v in samples.items()),
        key=lambda x: x[0]
    )

def analyze(samples):
    result = {
        "samples": len(samples),
        "successes": sum(ok for _, ok in samples),
        "failures": sum(not ok for _, ok in samples),
        "success_pct": "",
        "outage_episodes": 0,
        "observed_outage_seconds": "",
        "longest_episode_seconds": "",
        "right_censored": False
    }

    if not samples:
        return result

    result["success_pct"] = round(
        100 * result["successes"] / len(samples), 3
    )

    first_failure = None
    durations = []

    for time, ok in samples:
        if not ok and first_failure is None:
            first_failure = time
            result["outage_episodes"] += 1
        elif ok and first_failure is not None:
            durations.append((time-first_failure).total_seconds())
            first_failure = None

    if first_failure is not None:
        result["right_censored"] = True

    if durations:
        result["observed_outage_seconds"] = round(sum(durations), 3)
        result["longest_episode_seconds"] = round(max(durations), 3)

    return result

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="experiments/evaluation/openmrs")
    ap.add_argument("--output", default="analysis/results/openmrs")
    args = ap.parse_args()

    base = Path(args.base)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    rows = []

    for marker in sorted(base.rglob("COMPLETE")):
        directory = marker.parent

        if (directory/"INCOMPLETE").exists():
            continue
        if "invalid-attempts" in directory.parts:
            continue
        if "logical-runs" in directory.parts:
            continue

        try:
            rel = directory.relative_to(base).parts
        except ValueError:
            continue

        if len(rel) == 3 and rel[0] in ("scenario-b", "scenario-c"):
            scenario, mode, run = rel
            profile = "none"
        elif len(rel) == 4 and rel[0] == "scenario-e":
            scenario, profile, mode, run = rel
        else:
            continue

        if not run.startswith("run-"):
            continue

        samples = observations(directory/"recovery-observations.csv")
        result = analyze(samples)

        rows.append({
            "scenario": scenario,
            "profile": profile,
            "mode": mode,
            "run": run,
            "directory": str(directory),
            **result
        })

    columns = [
        "scenario", "profile", "mode", "run", "directory",
        "samples", "successes", "failures", "success_pct",
        "outage_episodes", "observed_outage_seconds",
        "longest_episode_seconds", "right_censored"
    ]

    with (output/"clinical-metrics.csv").open(
        "w", newline="", encoding="utf-8"
    ) as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    print("Clinical runs analyzed:", len(rows))
    print("Output:", output/"clinical-metrics.csv")

if __name__ == "__main__":
    main()