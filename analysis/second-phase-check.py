#!/usr/bin/env python3
"""Recompute the pooled second-phase results reported in the paper and check
them against the values printed in the manuscript.

Covers: the baseline ladder pooled over its four campaigns (H1, H2, decision
timing), the extended probe grid, the live-writer campaigns (H3), the
kubelet-hang (H6) and flapping-link (H7) campaigns and OpenMRS Scenario B
under clinical load. Reads the recorded evidence only; runs no
experiment. Prints PASS or FAIL per statement and exits 1 on any FAIL.

Usage:
    python3 analysis/second-phase-check.py [--evidence experiments/evaluation]
"""

import argparse
import csv
import glob
import importlib.util
import json
import math
import re
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LADDER = ["campaign-20261029T101038Z", "campaign-20261030T214135Z", "campaign-20261101T100434Z",
          "campaign-20261106T133133Z"]
KUBELET_HANG = "campaign-20261106T081657Z"
FLAPPING = "campaign-20261106T103922Z"
PROBE_EXT = "campaign-20261030T214135Z/probe-grid-ext"
LIVE_WRITER = ["campaign-20261029T201737Z", "campaign-20261030T042851Z", "campaign-20261031T111653Z",
               "campaign-20261106T173316Z"]

checks = []


def check(what, value, expected):
    ok = (abs(value - expected) <= 0.051) if isinstance(expected, float) else (value == expected)
    checks.append((what, value, expected, "PASS" if ok else "FAIL"))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def num(v):
    if v in ("", None, "nan"):
        return float("nan")
    return math.inf if v == "inf" else float(v)


def ladder(ev, al):
    runs = []
    with tempfile.TemporaryDirectory() as tmp:
        for c in LADDER:
            out = Path(tmp) / c
            subprocess.run([sys.executable, str(ROOT / "analysis" / "analyze-ladder.py"),
                            str(ev / "ladder" / c), "--output", str(out)],
                           check=True, stdout=subprocess.DEVNULL)
            with open(out / "ladder-runs.csv", newline="") as f:
                runs += list(csv.DictReader(f))
    for r in runs:
        r["replaced"] = r["original_replaced"] in ("True", "true", "1")
    check("ladder runs pooled", len(runs), 150)

    def cell(arm, cond, dur):
        return [r for r in runs if (r["arm"], r["condition"], r["fault_seconds_planned"]) == (arm, cond, dur)]

    for arm, expect in (("v0", (0, 10)), ("t10", (10, 10)), ("nx", (0, 0)), ("r2", (0, 10)), ("fa1", (0, 0))):
        for dur, e in (("120", expect[0]), ("600", expect[1])):
            rs = cell(arm, "rp", dur)
            check(f"{arm} replaced at {dur} s (of {len(rs)})", sum(r["replaced"] for r in rs), e)
    pvals = []
    for dur in ("120", "600"):
        fa = cell("fa1", "rp", dur)
        for k in ("v0", "t10", "r2"):
            c = cell(k, "rp", dur)
            a, b = sum(r["replaced"] for r in fa), sum(r["replaced"] for r in c)
            pvals.append(al.fisher_exact(a, len(fa) - a, b, len(c) - b))
    holm = al.holm(pvals)
    check("H1 Holm p, T10 at 120 s", round(holm[1], 5), 0.00006)
    check("H1 Holm p, V0/T10/R2 at 600 s", round(max(holm[3:]), 5), 0.00006)

    def restored(arm):
        return [num(r["w2_nodeport_restored_s"]) for r in cell(arm, "uw", "480")]
    fa, t10 = restored("fa1"), restored("t10")
    check("H2 FA1 median restoration (s)", round(statistics.median(fa), 1), 63.9)
    check("H2 T10 median restoration (s)", round(statistics.median(t10), 1), 62.1)
    check("H2 Cliff's delta", round(al.cliffs_delta(fa, t10), 2), 0.54)
    nx = cell("nx", "uw", "480")
    check("NX restored before the fault healed",
          sum(1 for r in nx if math.isfinite(num(r["w2_nodeport_restored_s"]))
              and num(r["w2_nodeport_restored_s"]) < num(r["fault_seconds_measured"])), 0)
    f1 = [r for r in runs if r["arm"] == "fa1"]
    check("FA1 decisions", len(f1), 30)
    check("FA1 earliest decision (s)", round(min(num(r["decision_s"]) for r in f1), 1), 42.5)
    check("FA1 latest decision (s)", round(max(num(r["decision_s"]) for r in f1), 1), 65.2)
    pres = [num(r["decision_s"]) - num(r["original_endpoint_unready_s"]) for r in f1 if r["condition"] == "rp"]
    rec = [num(r["decision_s"]) - num(r["original_endpoint_unready_s"]) for r in f1 if r["condition"] == "uw"]
    check("PRESERVE after endpoint not ready, max (s)", round(max(pres), 2), 0.95)
    check("RECOVER after endpoint not ready, max (s)", round(max(rec), 1), 10.1)
    check("controller CPU per run, max (millicores)", round(max(num(r["controller_cpu_fault_millicores"]) for r in f1), 2), 3.33)


def probe_ext(ev, al):
    rows, _ = al.analyse_probe_grid(ev / "ladder" / PROBE_EXT)
    k3 = {r["state"]: r["errors"] for r in rows if r["k"] == 3}
    check("extended grid trials", sum(r["trials"] for r in rows if r["k"] == 3), 500)
    check("delay 0.5 s false-RECOVER, k=3", k3.get("delay500"), 0)
    check("delay 1.0 s false-RECOVER, k=3", k3.get("delay1000"), 0)
    check("delay 1.5 s classified unreachable, k=3", k3.get("delay1500"), 100)
    check("70% loss false-RECOVER, k=3", k3.get("loss70"), 24)
    check("90% loss false-RECOVER, k=3", k3.get("loss90"), 87)


def live_writer(ev):
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([sys.executable, str(ROOT / "analysis" / "analyze-live-writer.py"),
                        *[str(ev / "live-writer" / c) for c in LIVE_WRITER], "--output", tmp],
                       check=True, stdout=subprocess.DEVNULL)
        s = json.loads((Path(tmp) / "live-writer-summary.json").read_text())
    f, u = s["fenced"], s["unfenced"]
    check("fenced runs", f["runs_complete"], 40)
    check("fenced runs with a post-fence commit", f["runs_with_original_commit_after_cutoff"], 0)
    check("fenced upper bound (%)", round(100 * f["upper_95_rate"], 1), 8.8)
    check("unfenced runs", u["runs_complete"], 20)
    check("unfenced runs with commits after release", u["runs_with_original_commit_after_cutoff"], 20)
    check("unfenced commits after release, total", u["original_commits_after_cutoff_total"], 20515)
    check("runs with overlapping writers", f["runs_with_overlapping_writers"] + u["runs_with_overlapping_writers"], 0)


def controller_episodes(log):
    """Suspicion episodes and decisions in one controller log."""
    text = log.read_text(errors="ignore")
    return (len(re.findall(r"^\[SUSPICION\]", text, re.M)),
            len(re.findall(r"decision=Preserve", text)),
            len(re.findall(r"decision=Recover", text)))


def other_faults(ev):
    for name, campaign, expect in (
        ("kubelet hang", KUBELET_HANG, {"v0": 5, "t10": 5, "fa1": 0}),
        ("flapping link", FLAPPING, {"v0": 0, "t10": 5, "fa1": 0}),
    ):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([sys.executable, str(ROOT / "analysis" / "analyze-ladder.py"),
                            str(ev / "ladder" / campaign), "--output", tmp],
                           check=True, stdout=subprocess.DEVNULL)
            with open(Path(tmp) / "ladder-runs.csv", newline="") as f:
                runs = list(csv.DictReader(f))
        check(f"{name}: runs", len(runs), 15)
        for arm, e in expect.items():
            n = sum(r["original_replaced"] in ("True", "true", "1") for r in runs if r["arm"] == arm)
            check(f"{name}: {arm} replaced (of 5)", n, e)
        s = p = rec = 0
        for d in sorted((ev / "ladder" / campaign / "runs").glob("*-fa1-*")):
            a, b, c = controller_episodes(d / "controller.log")
            s, p, rec = s + a, p + b, rec + c
        check(f"{name}: FA1 suspicion episodes", s, 5 if name == "kubelet hang" else 30)
        check(f"{name}: FA1 PRESERVE decisions", p, s)
        check(f"{name}: FA1 RECOVER decisions", rec, 0)


def ts(s):
    m = re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?", s)
    return datetime.fromisoformat(m.group(1) + (m.group(2) or ".0")[:7] + "+00:00").timestamp()


def openmrs_load(ev):
    rows = []
    for f in glob.glob(str(ev / "openmrs" / "load" / "*" / "load.csv")):
        with open(f, newline="") as fh:
            rows += [(ts(r["utc"]), r["ok"] == "1") for r in csv.DictReader(fh)]
    rows.sort()
    after = {}
    for d in sorted(glob.glob(str(ev / "openmrs" / "scenario-b" / "*" / "run-10[1-5]"))):
        d = Path(d)
        if not (d / "COMPLETE").exists():
            continue
        f0, f1 = ts((d / "fault-start-time.txt").read_text()), ts((d / "fault-clear-time.txt").read_text())
        nxt = next((t - f1 for t, ok in rows if t > f0 + 120 and ok), None)
        if nxt is not None and nxt < 120:
            after.setdefault(d.parent.name, []).append(nxt)
    check("OpenMRS load runs restored after the heal", sum(len(v) for v in after.values()), 11)
    fa = after.get("FA1", [])
    check("FA1 back after heal, max (s)", round(max(fa), 1) if fa else None, 9.1)
    rep = after.get("T5", []) + after.get("T10", []) + after.get("T30", [])
    check("T5/T10/T30 runs", len(rep), 8)
    check("T5/T10/T30 back after heal, min (s)", round(min(rep)) if rep else None, 16)
    check("T5/T10/T30 back after heal, max (s)", round(max(rep)) if rep else None, 33)
    check("V0 runs back within 120 s of the heal", len(after.get("V0", [])), 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", default=str(ROOT / "experiments" / "evaluation"))
    a = ap.parse_args()
    ev = Path(a.evidence)
    al = load_module("analyze_ladder", ROOT / "analysis" / "analyze-ladder.py")
    for part in (ladder, probe_ext):
        part(ev, al)
    live_writer(ev)
    other_faults(ev)
    openmrs_load(ev)
    for what, v, e, st in checks:
        print(f"{st}  {what:52s} {v}  (paper: {e})")
    failed = sum(1 for c in checks if c[3] == "FAIL")
    print(f"\nSECOND_PHASE: {len(checks) - failed}/{len(checks)} PASS")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
