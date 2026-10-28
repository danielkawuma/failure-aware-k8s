#!/usr/bin/env python3
"""Analysis of the live-writer fencing campaign (H3).

For each completed run, from the rows read back by the verifier:
  - commits by the original writer after the fence was verified
    (fenced arm) or after the replacement was started (unfenced arm),
    with the original's commit times converted to the local clock using
    the measured Worker1 clock offset;
  - whether every acknowledged write of the original is present
    (durability), and whether the original and replacement writers
    committed in overlapping intervals;
  - whether the replacement became ready and how many rows it committed.

Standard library only.

Usage:
    python3 analysis/analyze-live-writer.py experiments/evaluation/live-writer/CURRENT \
        --output analysis/results/live-writer
"""

import argparse
import csv
import json
import math
import re
from datetime import datetime
from pathlib import Path

_TS = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?")


def ts(value):
    m = _TS.search(value or "")
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]
    return datetime.fromisoformat(m.group(1) + frac + "+00:00").timestamp()


def text(p):
    return p.read_text().strip() if p.exists() else ""


def beta_upper(x, n, alpha=0.05):
    """Clopper-Pearson upper bound by bisection on the binomial CDF."""
    if n == 0:
        return float("nan")
    if x == n:
        return 1.0

    def cdf(p):
        return sum(math.comb(n, k) * p ** k * (1 - p) ** (n - k) for k in range(x + 1))

    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if cdf(mid) > alpha / 2:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def analyse(rdir, arm):
    offsets = {}
    for r in csv.DictReader((rdir / "clock-offsets.csv").open()):
        try:
            offsets[r["host"]] = float(r["offset_s"])
        except (ValueError, KeyError):
            offsets[r["host"]] = 0.0
    off1 = offsets.get("worker1", 0.0)
    off2 = offsets.get("worker2", 0.0)

    rows = []
    for line in text(rdir / "committed-rows.csv").splitlines():
        parts = line.split(",")
        if len(parts) == 3 and parts[0].isdigit():
            rows.append((int(parts[0]), parts[1], ts(parts[2])))

    fault = ts(text(rdir / "fault-time.txt"))
    suspicion = ts(text(rdir / "suspicion-time.txt"))
    fence = ts(text(rdir / "fence-verified-time.txt"))
    repl_start = ts(text(rdir / "replacement-start-time.txt"))
    repl_ready_raw = text(rdir / "replacement-sql-ready-time.txt")
    repl_ready = ts(repl_ready_raw)
    clear = ts(text(rdir / "fault-clear-time.txt"))

    cutoff = fence if arm == "fenced" else repl_start

    # Convert each writer's server-side commit time to the local clock.
    orig = [(s, t - off1) for s, w, t in rows if w == "original" and t is not None]
    repl = [(s, t - off2) for s, w, t in rows if w == "replacement" and t is not None]

    # Fenced arm: any original commit after the fence counts, whenever it
    # landed. Unfenced arm: original commits between the replacement's
    # release and the end of the partition, while native recovery had
    # already released the workload.
    end = float("inf") if arm == "fenced" else (clear or float("inf"))
    after_cutoff = [s for s, t in orig if cutoff is not None and cutoff < t <= end]
    margin = abs(off1) + 0.5
    after_cutoff_margin = [s for s, t in orig if cutoff is not None and cutoff + margin < t <= end]

    acked = set()
    for line in text(rdir / "original-writer.csv").splitlines():
        parts = line.split(",")
        if len(parts) == 3 and parts[2] == "ack":
            acked.add(int(parts[1]))
    committed_orig = {s for s, _ in orig}
    lost_acked = sorted(acked - committed_orig)

    overlap = False
    if orig and repl:
        overlap = not (max(t for _, t in orig) < min(t for _, t in repl)
                       or max(t for _, t in repl) < min(t for _, t in orig))

    return {
        "run_id": rdir.name,
        "arm": arm,
        "suspicion_after_fault_s": (suspicion - fault) if suspicion and fault else float("nan"),
        "fence_after_suspicion_s": (fence - suspicion) if fence and suspicion else float("nan"),
        "original_commits_total": len(orig),
        "original_last_commit_after_cutoff_s": (max(t for _, t in orig) - cutoff) if orig and cutoff else float("nan"),
        "original_commits_after_cutoff": len(after_cutoff),
        "original_commits_after_cutoff_beyond_clock_margin": len(after_cutoff_margin),
        "clock_offset_worker1_s": off1,
        "original_acked": len(acked),
        "original_acked_but_not_committed": len(lost_acked),
        "replacement_ready": repl_ready is not None,
        "replacement_ready_after_start_s": (repl_ready - repl_start) if repl_ready and repl_start else float("nan"),
        "replacement_commits": len(repl),
        "writers_overlapped_in_time": overlap,
        "fault_seconds": (clear - fault) if clear and fault else float("nan"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("campaign")
    ap.add_argument("--output", default="analysis/results/live-writer")
    a = ap.parse_args()
    cdir = Path(a.campaign).resolve()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)

    plan = list(csv.DictReader((cdir / "plan.csv").open()))
    inventory, results = [], []
    for p in plan:
        rdir = cdir / "runs" / p["run_id"]
        status = "COMPLETE" if (rdir / "COMPLETE").exists() else ("ABORTED" if (rdir / "ABORTED").exists() else "NOT_STARTED")
        inventory.append({**p, "status": status, "abort_reason": text(rdir / "ABORTED")})
        if status == "COMPLETE":
            results.append(analyse(rdir, p["arm"]))

    for name, rows in (("live-writer-inventory.csv", inventory), ("live-writer-runs.csv", results)):
        if rows:
            with (out / name).open("w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)

    summary = {"campaign": cdir.name, "seed": text(cdir / "seed.txt")}
    for arm in ("fenced", "unfenced"):
        rs = [r for r in results if r["arm"] == arm]
        violating = sum(1 for r in rs if r["original_commits_after_cutoff"] > 0)
        summary[arm] = {
            "runs_complete": len(rs),
            "runs_aborted": sum(1 for i in inventory if i["arm"] == arm and i["status"] == "ABORTED"),
            "runs_with_original_commit_after_cutoff": violating,
            "upper_95_rate": beta_upper(violating, len(rs)),
            "original_commits_after_cutoff_total": sum(r["original_commits_after_cutoff"] for r in rs),
            "replacement_ready_runs": sum(1 for r in rs if r["replacement_ready"]),
            "runs_with_acked_write_missing": sum(1 for r in rs if r["original_acked_but_not_committed"] > 0),
            "runs_with_overlapping_writers": sum(1 for r in rs if r["writers_overlapped_in_time"]),
        }

    f, u = summary["fenced"], summary["unfenced"]
    if f["runs_complete"] == 0:
        h3 = "NOT TESTED"
    elif f["runs_with_original_commit_after_cutoff"] > 0:
        h3 = "REJECTED"
    elif u["runs_with_original_commit_after_cutoff"] == 0:
        h3 = "INCONCLUSIVE (the unfenced arm showed no post-release commits, so the test cannot discriminate)"
    else:
        h3 = "ACCEPTED"
    summary["H3"] = h3
    (out / "live-writer-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
