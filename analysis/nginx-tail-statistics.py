#!/usr/bin/env python3
"""Tail and robust statistics for the Nginx Scenario B and C cohorts.

Adds, to the per-run metrics already reproduced by `make reproduce`:
median with a BCa bootstrap 95 % interval, p95 and p99 (n >= 20), and,
for Scenario C, Cliff's delta with permutation p-values adjusted by Holm.
Scenario B excludes the aborted attempt run-019 and reports run-003's
HTTP outage as unobserved.

Standard library only; reuses the statistics in analyze-ladder.py.

Usage:
    python3 analysis/nginx-tail-statistics.py --output analysis/results/nginx-tail
"""

import argparse
import csv
import importlib.util
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ladder", HERE / "analyze-ladder.py")
L = importlib.util.module_from_spec(spec)
spec.loader.exec_module(L)

B_SOURCE = HERE / "results" / "reproduced" / "nginx-scenario-b-manuscript-metrics.csv"
C_SOURCE = HERE / "results" / "reproduced" / "nginx-bc-run-metrics.csv"

ABORTED = {("scenario-b", "failure-aware", "run-019")}
UNOBSERVED_HTTP = {("scenario-b", "failure-aware", "run-003")}

METRICS = {
    "scenario-b": [
        ("native", "replacement_pending_delay_s", "Replacement pending"),
        ("native", "replacement_running_delay_s", "Replacement running"),
        ("native", "http_outage_s", "HTTP outage"),
        ("failure-aware", "suspicion_delay_s", "Suspicion delay"),
        ("failure-aware", "decision_delay_s", "Decision delay"),
        ("failure-aware", "http_outage_s", "HTTP outage"),
    ],
    "scenario-c": [
        ("native", "replacement_pending_delay_s", "Replacement pending"),
        ("native", "replacement_running_delay_s", "Replacement running"),
        ("native", "service_recovery_s", "End-to-end recovery (ERL)"),
        ("native", "http_outage_s", "HTTP outage (SID)"),
        ("failure-aware", "suspicion_delay_s", "Suspicion delay (FDL)"),
        ("failure-aware", "decision_delay_s", "Decision delay"),
        ("failure-aware", "recovery_release_delay_s", "Recovery-release delay"),
        ("failure-aware", "replacement_pending_delay_s", "Replacement pending"),
        ("failure-aware", "replacement_running_delay_s", "Replacement running"),
        ("failure-aware", "service_recovery_s", "End-to-end recovery (ERL)"),
        ("failure-aware", "http_outage_s", "HTTP outage (SID)"),
    ],
}
COMPARE_C = [("replacement_running_delay_s", "Replacement running"),
             ("service_recovery_s", "End-to-end recovery (ERL)"),
             ("http_outage_s", "HTTP outage (SID)")]


def values(rows, scenario, mode, field):
    out = []
    for r in rows:
        key = (r["scenario"], r["mode"], r["run"])
        if r["scenario"] != scenario or r["mode"] != mode or key in ABORTED:
            continue
        if field == "http_outage_s" and key in UNOBSERVED_HTTP:
            continue
        try:
            v = float(r[field])
        except (ValueError, KeyError):
            continue
        if math.isfinite(v):
            out.append(v)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default=str(HERE / "results" / "nginx-tail"))
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)

    bc = list(csv.DictReader(C_SOURCE.open()))
    # Scenario B: the manuscript cohort file holds the 33 Failure-Aware
    # attempts; the 30 native runs are in the Nginx B/C run metrics.
    b_rows = list(csv.DictReader(B_SOURCE.open())) + [
        r for r in bc if r["scenario"] == "scenario-b" and r["mode"] == "native"]
    c_rows = [r for r in bc if r["scenario"] == "scenario-c"]
    sources = {"scenario-b": b_rows, "scenario-c": c_rows}

    table = []
    for scenario, metrics in METRICS.items():
        for mode, field, label in metrics:
            v = values(sources[scenario], scenario, mode, field)
            med, lo, hi = L.bca_median(v) if v else (float("nan"),) * 3
            table.append({
                "scenario": scenario, "mode": mode, "metric": label, "n": len(v),
                "median": med, "bca_low": lo, "bca_high": hi,
                "p95": L.percentile(v, 0.95) if len(v) >= 20 else float("nan"),
                "p99": L.percentile(v, 0.99) if len(v) >= 20 else float("nan"),
                "min": min(v) if v else float("nan"), "max": max(v) if v else float("nan"),
            })
    L.write_csv(out / "nginx-tail-statistics.csv", table)

    # Scenario C native vs Failure-Aware: Cliff's delta with Holm-adjusted
    # exact permutation p-values on the difference in medians.
    comps, pvals = [], []
    for field, label in COMPARE_C:
        nv = values(c_rows, "scenario-c", "native", field)
        fv = values(c_rows, "scenario-c", "failure-aware", field)
        delta = L.cliffs_delta(nv, fv)
        # Exact one-sided rank argument: when every native value exceeds
        # every Failure-Aware value, the permutation p-value equals
        # 1 / C(n1 + n2, n1); otherwise report the Monte Carlo estimate.
        n1, n2 = len(nv), len(fv)
        if delta == 1.0:
            p = 2.0 / math.comb(n1 + n2, n1)
        else:
            import random
            rng = random.Random(L.SEED)
            pooled = nv + fv
            obs = abs(L.statistics.median(nv) - L.statistics.median(fv))
            hits = 0
            for _ in range(20000):
                rng.shuffle(pooled)
                if abs(L.statistics.median(pooled[:n1]) - L.statistics.median(pooled[n1:])) >= obs:
                    hits += 1
            p = (hits + 1) / 20001
        comps.append({"metric": label, "native_n": n1, "fa_n": n2, "cliffs_delta": delta, "p_two_sided": p})
        pvals.append(p)
    for c, adj in zip(comps, L.holm(pvals)):
        c["p_holm"] = adj
    L.write_csv(out / "nginx-scenario-c-comparisons.csv", comps)

    # Scenario B retention: Fisher exact on valid runs.
    fa_valid = [r for r in b_rows if r["scenario"] == "scenario-b" and r["mode"] == "failure-aware"
                and (r["scenario"], r["mode"], r["run"]) not in ABORTED]
    nat = [r for r in b_rows if r["scenario"] == "scenario-b" and r["mode"] == "native"]
    fa_repl = sum(1 for r in fa_valid if r["replacement_occurred"] == "True")
    nat_repl = sum(1 for r in nat if r["replacement_occurred"] == "True")
    p = L.fisher_exact(len(fa_valid) - fa_repl, fa_repl, len(nat) - nat_repl, nat_repl)
    L.write_csv(out / "nginx-scenario-b-retention.csv", [{
        "fa_valid_runs": len(fa_valid), "fa_retained": len(fa_valid) - fa_repl,
        "native_runs": len(nat), "native_retained": len(nat) - nat_repl, "fisher_p": p,
        "fa_retention_cp_low": L.clopper_pearson(len(fa_valid) - fa_repl, len(fa_valid))[0],
        "native_retention_cp_high": L.clopper_pearson(len(nat) - nat_repl, len(nat))[1],
    }])
    for row in table:
        print(row["scenario"], row["mode"], row["metric"], row["n"],
              L.fmt(row["median"]), f'[{L.fmt(row["bca_low"])}, {L.fmt(row["bca_high"])}]',
              L.fmt(row["p95"]), L.fmt(row["p99"]))
    for c in comps:
        print(c)
    print("retention", len(fa_valid) - fa_repl, "/", len(fa_valid), "vs", len(nat) - nat_repl, "/", len(nat), "p=", p)


if __name__ == "__main__":
    main()
