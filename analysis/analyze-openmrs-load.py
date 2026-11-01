#!/usr/bin/env python3
"""OpenMRS Scenario B under load: client cost per run.

Joins the load CSV with each run's fault window and reports, per run:
requests and success share in the 120 s before the fault and during the
fault, median and p95 latency of successful requests, the longest run of
failed requests (seconds, the user-visible outage), and whether the
original backend was replaced. Standard library only.

Usage:
  python3 analysis/analyze-openmrs-load.py <load-campaign-dir> \
      experiments/evaluation/openmrs/scenario-b --runs-from 101 \
      --output analysis/results/openmrs-load
"""
import argparse, csv, re, statistics
from datetime import datetime
from pathlib import Path


def ts(s):
    m = re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?", s or "")
    return datetime.fromisoformat(m.group(1) + (m.group(2) or ".0")[:7] + "+00:00").timestamp() if m else None


def pct(v, q):
    v = sorted(v); return v[min(len(v) - 1, int(q * len(v)))] if v else None


def window(rows, a, b):
    sel = [r for r in rows if a <= r[0] < b]
    ok = [r for r in sel if r[2]]
    streak = cur = 0.0; last = None
    for t, _, good in sel:
        if good:
            last = None; continue
        last = t if last is None else last
        streak = max(streak, t - last)
    lat = [r[1] for r in ok]
    return {"requests": len(sel), "success": round(len(ok) / len(sel), 4) if sel else "",
            "p50_ms": round(statistics.median(lat), 1) if lat else "", "p95_ms": round(pct(lat, 0.95), 1) if lat else "",
            "longest_failure_s": round(streak, 1)}


ap = argparse.ArgumentParser()
ap.add_argument("load_dir"); ap.add_argument("scenario_b_dir")
ap.add_argument("--runs-from", type=int, default=101); ap.add_argument("--output", default="analysis/results/openmrs-load")
a = ap.parse_args()
rows = []
with open(Path(a.load_dir) / "load.csv") as f:
    for r in csv.DictReader(f):
        t = ts(r["utc"])
        if t: rows.append((t, float(r["latency_ms"]), r["ok"] == "1"))
rows.sort()
out = []
for d in sorted(Path(a.scenario_b_dir).glob("*/run-*")):
    try:
        n = int(d.name.split("-")[-1])
    except ValueError:
        continue
    if n < a.runs_from or not (d / "fault-start-time.txt").exists() or not (d / "fault-clear-time.txt").exists():
        continue
    f0 = ts((d / "fault-start-time.txt").read_text()); f1 = ts((d / "fault-clear-time.txt").read_text())
    before = (d / "old-backend-before-fault.txt").read_text().split() if (d / "old-backend-before-fault.txt").exists() else []
    pods = (d / "recovery-pods.txt").read_text() if (d / "recovery-pods.txt").exists() else ""
    replaced = "" if not before else (before[0] not in pods)
    b = window(rows, f0 - 120, f0); fw = window(rows, f0, f1 + 60)
    out.append({"mode": d.parent.name, "run": d.name, "fault_s": round(f1 - f0, 1), "replaced": replaced,
                **{"before_" + k: v for k, v in b.items()}, **{"fault_" + k: v for k, v in fw.items()}})
o = Path(a.output); o.mkdir(parents=True, exist_ok=True)
if out:
    with open(o / "openmrs-load-runs.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0]), lineterminator="\n"); w.writeheader(); w.writerows(out)
for m in sorted({r["mode"] for r in out}):
    rs = [r for r in out if r["mode"] == m]
    s = [r["fault_success"] for r in rs if r["fault_success"] != ""]
    g = [r["fault_longest_failure_s"] for r in rs]
    print(f"{m}: runs={len(rs)} replaced={sum(1 for r in rs if r['replaced'] is True)} "
          f"fault-window success median={statistics.median(s) if s else 'n/a'} longest failure median={statistics.median(g) if g else 'n/a'} s")
