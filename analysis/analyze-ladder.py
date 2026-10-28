#!/usr/bin/env python3
"""Analysis of the Midterm 2 supplementary campaign.

Reads one campaign directory written by scripts/ladder/campaign.sh and
writes per-run metrics, per-cell summaries, and the verdicts for the
pre-registered hypotheses H1, H2, H4 and H5 (docs/hypotheses-midterm2.md).

Standard library only.

Usage:
    python3 analysis/analyze-ladder.py experiments/evaluation/ladder/CURRENT \
        --output analysis/results/ladder
"""

import argparse
import csv
import json
import math
import random
import re
import statistics
from datetime import datetime
from pathlib import Path

ARMS = ["v0", "t10", "nx", "r2", "fa1"]
NATIVE_COMPARATORS_H1 = ["v0", "t10", "r2"]
H2_MARGIN_S = 15.0
BUDGET_CPU_M = 20.0
BUDGET_RSS_MIB = 32.0
BUDGET_NET_BPS = 1024.0
BOOTSTRAP = 10000
SEED = 20261029

# ------------------------------------------------------------------
# Time parsing
# ------------------------------------------------------------------

_TS = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?")


def ts(value):
    if not value:
        return None
    m = _TS.search(value.strip())
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]
    return datetime.fromisoformat(m.group(1) + frac + "+00:00").timestamp()


def read_csv(path):
    if not path.exists():
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def read_text(path):
    return path.read_text().strip() if path.exists() else ""

# ------------------------------------------------------------------
# Statistics (standard library)
# ------------------------------------------------------------------


def betacf(a, b, x):
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > 1e-300 else 1e-300)
    h = d
    for m in range(1, 300):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > 1e-300 else 1e-300)
        c = 1.0 + aa / c if abs(1.0 + aa / c) > 1e-300 else 1e-300
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > 1e-300 else 1e-300)
        c = 1.0 + aa / c if abs(1.0 + aa / c) > 1e-300 else 1e-300
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < 3e-14:
            break
    return h


def betainc(a, b, x):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    lbeta = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    front = math.exp(lbeta + a * math.log(x) + b * math.log(1 - x))
    if x < (a + 1) / (a + b + 2):
        return front * betacf(a, b, x) / a
    return 1 - front * betacf(b, a, 1 - x) / b


def beta_ppf(q, a, b):
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if betainc(a, b, mid) < q:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def clopper_pearson(x, n, alpha=0.05):
    if n == 0:
        return (float("nan"), float("nan"))
    lo = 0.0 if x == 0 else beta_ppf(alpha / 2, x, n - x + 1)
    hi = 1.0 if x == n else beta_ppf(1 - alpha / 2, x + 1, n - x)
    return lo, hi


def wilson(x, n, z=1.959964):
    if n == 0:
        return (float("nan"), float("nan"))
    p = x / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def t_cdf(t, df):
    x = df / (df + t * t)
    p = 0.5 * betainc(df / 2, 0.5, x)
    return 1 - p if t > 0 else p


def t_ppf(q, df):
    lo, hi = -100.0, 100.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if t_cdf(mid, df) < q:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def fisher_exact(a, b, c, d):
    """Two-sided Fisher exact test for [[a, b], [c, d]]."""
    r1, r2, c1 = a + b, c + d, a + c
    n = r1 + r2

    def logp(x):
        return (math.lgamma(r1 + 1) + math.lgamma(r2 + 1) + math.lgamma(c1 + 1) + math.lgamma(n - c1 + 1)
                - math.lgamma(n + 1) - math.lgamma(x + 1) - math.lgamma(r1 - x + 1)
                - math.lgamma(c1 - x + 1) - math.lgamma(r2 - c1 + x + 1))

    lo, hi = max(0, c1 - r2), min(r1, c1)
    p0 = logp(a)
    total = sum(math.exp(logp(x)) for x in range(lo, hi + 1) if logp(x) <= p0 + 1e-9)
    return min(1.0, total)


def cliffs_delta(xs, ys):
    if not xs or not ys:
        return float("nan")
    gt = sum(1 for x in xs for y in ys if x > y)
    lt = sum(1 for x in xs for y in ys if x < y)
    return (gt - lt) / (len(xs) * len(ys))


def holm(pvalues):
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i])
    adjusted = [0.0] * len(pvalues)
    running = 0.0
    m = len(pvalues)
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (m - rank) * pvalues[i]))
        adjusted[i] = running
    return adjusted


def norm_ppf(p):
    lo, hi = -10.0, 10.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if 0.5 * (1 + math.erf(mid / math.sqrt(2))) < p:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def norm_cdf(z):
    return 0.5 * (1 + math.erf(z / math.sqrt(2)))


def bca_median(values, alpha=0.05):
    """Median with a BCa bootstrap interval."""
    xs = sorted(values)
    n = len(xs)
    if n == 0:
        return (float("nan"), float("nan"), float("nan"))
    est = statistics.median(xs)
    if n < 3 or len(set(xs)) == 1:
        return (est, min(xs), max(xs))
    rng = random.Random(SEED)
    boots = sorted(statistics.median(rng.choices(xs, k=n)) for _ in range(BOOTSTRAP))
    below = sum(1 for b in boots if b < est) + 0.5 * sum(1 for b in boots if b == est)
    z0 = norm_ppf(min(max(below / BOOTSTRAP, 1e-6), 1 - 1e-6))
    jack = [statistics.median(xs[:i] + xs[i + 1:]) for i in range(n)]
    jm = sum(jack) / n
    num = sum((jm - j) ** 3 for j in jack)
    den = 6 * (sum((jm - j) ** 2 for j in jack) ** 1.5)
    acc = num / den if den else 0.0

    def q(p):
        z = norm_ppf(p)
        adj = norm_cdf(z0 + (z0 + z) / (1 - acc * (z0 + z)))
        idx = min(BOOTSTRAP - 1, max(0, int(adj * BOOTSTRAP)))
        return boots[idx]

    return (est, q(alpha / 2), q(1 - alpha / 2))


def percentile(values, p):
    xs = sorted(values)
    if not xs:
        return float("nan")
    k = (len(xs) - 1) * p
    f, c = math.floor(k), math.ceil(k)
    return xs[f] if f == c else xs[f] + (xs[c] - xs[f]) * (k - f)


def one_sided_upper(values, alpha=0.05):
    n = len(values)
    if n < 2:
        return float("nan")
    m = statistics.mean(values)
    s = statistics.stdev(values)
    return m + t_ppf(1 - alpha, n - 1) * s / math.sqrt(n)


def welch_upper(xs, ys, alpha=0.05):
    """One-sided upper bound for mean(xs) - mean(ys)."""
    nx, ny = len(xs), len(ys)
    if nx < 2 or ny < 2:
        return float("nan")
    vx, vy = statistics.variance(xs) / nx, statistics.variance(ys) / ny
    se = math.sqrt(vx + vy)
    df = (vx + vy) ** 2 / (vx ** 2 / (nx - 1) + vy ** 2 / (ny - 1)) if se else nx + ny - 2
    return statistics.mean(xs) - statistics.mean(ys) + t_ppf(1 - alpha, df) * se


def fmt(x, digits=2):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return ""
    return f"{x:.{digits}f}"

# ------------------------------------------------------------------
# Ladder runs
# ------------------------------------------------------------------


def outage_intervals(samples, start, end):
    """samples: sorted (t, ok). Returns failure intervals inside [start, end]
    as (first failed sample, first later successful sample or None)."""
    out, open_at = [], None
    for t, ok in samples:
        if t < start or t > end:
            continue
        if not ok and open_at is None:
            open_at = t
        elif ok and open_at is not None:
            out.append((open_at, t))
            open_at = None
    if open_at is not None:
        out.append((open_at, None))
    return out


def max_gap(samples, start, end):
    times = [t for t, _ in samples if start <= t <= end]
    return max((b - a for a, b in zip(times, times[1:])), default=float("nan"))


def analyse_run(rdir):
    meta = json.loads(read_text(rdir / "experiment-metadata.json"))
    fault = ts(read_text(rdir / "fault-time.txt"))
    clear = ts(read_text(rdir / "fault-clear-time.txt"))
    observe_end = clear + 60 if clear else None
    original = meta["original_pod"]

    start_pods = set()
    for line in read_text(rdir / "pods-before.txt").splitlines()[1:]:
        if line.startswith("baseline-web-"):
            start_pods.add(line.split()[0])

    pods = read_csv(rdir / "pod-observations.csv")
    evicted_at = None
    replacement_running_at = None
    replacement_node = ""
    for r in pods:
        t = ts(r["timestamp_utc"])
        if r["pod"] == original and r.get("deletion_timestamp") and evicted_at is None:
            evicted_at = t
        if (r["pod"] not in start_pods and r["phase"] == "Running" and not r.get("deletion_timestamp")
                and replacement_running_at is None and t >= fault):
            replacement_running_at = t
            replacement_node = r.get("node", "")

    after = read_text(rdir / "pods-after.txt")
    original_present_after = original in after
    original_replaced = (evicted_at is not None) or (not original_present_after) or (replacement_running_at is not None)

    # Harness: fixed Service path through the Worker2 NodePort.
    w2 = sorted((ts(r["timestamp_utc"]), r.get("success", "").lower() == "true")
                for r in read_csv(rdir / "http-observations.csv"))
    # Direct Worker1 NodePort probe (the controller's verification path).
    w1 = sorted((ts(r["timestamp_utc"]), r.get("success", "").lower() == "true")
                for r in read_csv(rdir / "worker1-nodeport-observations.csv"))

    client = []
    for line in read_text(rdir / "client-clusterip-observations.csv").splitlines():
        parts = line.strip().split(",")
        if len(parts) == 2 and parts[1] in ("ok", "fail"):
            client.append((ts(parts[0]), parts[1] == "ok"))
    client.sort()

    def path_metrics(samples, label):
        if not samples or fault is None or clear is None:
            nan = float("nan")
            return {f"{label}_n": 0, f"{label}_success_fraction": nan, f"{label}_first_failure_s": nan,
                    f"{label}_restored_s": nan, f"{label}_longest_outage_s": nan,
                    f"{label}_max_sample_gap_s": nan}
        in_fault = [ok for t, ok in samples if fault <= t <= clear]
        outs = outage_intervals(samples, fault, observe_end)
        first = outs[0] if outs else None
        restored = None
        if first is not None and first[1] is not None:
            restored = first[1] - fault
        longest = 0.0
        for a, b in outs:
            longest = max(longest, (b if b is not None else observe_end) - a)
        return {
            f"{label}_n": len(in_fault),
            f"{label}_success_fraction": (sum(in_fault) / len(in_fault)) if in_fault else float("nan"),
            f"{label}_first_failure_s": (first[0] - fault) if first else float("nan"),
            f"{label}_restored_s": restored if restored is not None else (float("nan") if first is None else float("inf")),
            f"{label}_longest_outage_s": longest,
            f"{label}_max_sample_gap_s": max_gap(samples, fault, observe_end),
        }

    metrics = {}
    metrics.update(path_metrics(w1, "w1_nodeport"))
    metrics.update(path_metrics(w2, "w2_nodeport"))
    metrics.update(path_metrics(client, "clusterip"))

    eps = read_csv(rdir / "endpointslice-observations.csv")
    original_unready_at = None
    no_ready_seconds = 0
    for r in eps:
        t = ts(r["timestamp_utc"])
        payload = r.get("endpoints", "")
        if fault and t >= fault and original_unready_at is None and f"{original}:" in payload:
            seg = [s for s in payload.split(";") if s.startswith(original + ":")]
            if seg and "ready=false" in seg[0]:
                original_unready_at = t
        if fault and clear and fault <= t <= clear and "ready=true" not in payload and payload != "API_ERROR":
            no_ready_seconds += 1

    decision, decision_at = "", None
    for line in read_text(rdir / "controller.log").splitlines():
        if line.startswith("[DECISION]"):
            m = re.search(r"decision=(\w+)", line)
            decision = m.group(1) if m else ""
            decision_at = ts(line)
            break

    samples = read_csv(rdir / "controller-resource-samples.csv")
    cpu_fault_m, rss_max_mib, windows = float("nan"), float("nan"), []
    in_fault = [(ts(r["timestamp_utc"]), int(r["cpu_ticks"]), int(r["clk_tck"]), int(r["rss_kib"] or 0))
                for r in samples if r.get("cpu_ticks")]
    in_fault = [s for s in in_fault if fault and clear and fault <= s[0] <= clear]
    if len(in_fault) >= 2:
        dt = in_fault[-1][0] - in_fault[0][0]
        if dt > 0:
            cpu_fault_m = (in_fault[-1][1] - in_fault[0][1]) / in_fault[0][2] / dt * 1000
        rss_max_mib = max(s[3] for s in in_fault) / 1024
        w0 = in_fault[0][0]
        k = 0
        while True:
            seg = [s for s in in_fault if w0 + 60 * k <= s[0] < w0 + 60 * (k + 1)]
            if len(seg) < 50:
                break
            span = seg[-1][0] - seg[0][0]
            windows.append(((seg[-1][1] - seg[0][1]) / seg[0][2] / span * 1000 if span else float("nan"),
                            statistics.mean(s[3] for s in seg) / 1024))
            k += 1

    row = {
        "run_id": meta["run_id"],
        "arm": meta["arm"],
        "condition": meta["condition"],
        "fault_seconds_planned": meta["fault_seconds"],
        "fault_seconds_measured": (clear - fault) if fault and clear else float("nan"),
        "original_pod": original,
        "original_replaced": original_replaced,
        "original_evicted_s": (evicted_at - fault) if evicted_at else float("nan"),
        "replacement_running_s": (replacement_running_at - fault) if replacement_running_at else float("nan"),
        "replacement_node": replacement_node,
        "original_endpoint_unready_s": (original_unready_at - fault) if original_unready_at else float("nan"),
        "seconds_without_ready_endpoint": no_ready_seconds,
        "decision": decision,
        "decision_s": (decision_at - fault) if decision_at else float("nan"),
        "controller_cpu_fault_millicores": cpu_fault_m,
        "controller_rss_max_mib": rss_max_mib,
    }
    row.update(metrics)
    return row, windows

# ------------------------------------------------------------------
# Probe grid and overhead
# ------------------------------------------------------------------


def analyse_probe_grid(pdir):
    trials = read_csv(pdir / "trials.csv")
    if not trials:
        return [], {}
    attempts = read_csv(pdir / "attempts.csv")
    first_fail = {}
    for a in attempts:
        if a["attempt"] == "1":
            first_fail.setdefault(a["state"], []).append(a["success"] != "True")
    rows, worst = [], {}
    states = sorted({t["state"] for t in trials}, key=lambda s: ["healthy", "loss10", "loss30", "loss50", "delay2500", "down"].index(s) if s in ["healthy", "loss10", "loss30", "loss50", "delay2500", "down"] else 99)
    for s in states:
        ts_ = [t for t in trials if t["state"] == s]
        truth = ts_[0]["ground_truth"]
        p_single = sum(first_fail.get(s, [])) / max(1, len(first_fail.get(s, [])))
        for k in (1, 3, 5):
            cls = [t[f"class_k{k}"] for t in ts_]
            n = len(cls)
            if truth == "reachable":
                errors = sum(1 for c in cls if c == "unreachable")
                kind = "false_recover"
            else:
                errors = sum(1 for c in cls if c != "unreachable")
                kind = "false_preserve"
            lo, hi = wilson(errors, n)
            rows.append({
                "state": s, "ground_truth": truth, "k": k, "trials": n, "error_kind": kind,
                "errors": errors, "rate": errors / n if n else float("nan"),
                "wilson_low": lo, "wilson_high": hi,
                "single_attempt_failure_p": p_single,
                "independent_prediction_p_pow_k": p_single ** k if truth == "reachable" else float("nan"),
                "indeterminate": sum(1 for c in cls if c == "indeterminate"),
            })
            worst[(s, k)] = (errors, n)
    return rows, worst


def analyse_overhead(odir):
    rows = read_csv(odir / "controller-overhead-windows.csv")
    by_window = {}
    for r in rows:
        by_window.setdefault((r["run_id"], r["mode"]), []).append(r)
    out = []
    for (wid, mode), rs in sorted(by_window.items()):
        rs.sort(key=lambda r: r["timestamp"])
        cpu = [float(r["cpu_millicores"]) for r in rs[1:]]
        rss = [float(r["rss_mib"]) for r in rs]
        t0, t1 = ts(rs[0]["timestamp"]), ts(rs[-1]["timestamp"])
        span = (t1 - t0) if t0 and t1 else float("nan")
        net = ((int(rs[-1]["rx_bytes"]) - int(rs[0]["rx_bytes"])) + (int(rs[-1]["tx_bytes"]) - int(rs[0]["tx_bytes"]))) / span if span else float("nan")
        out.append({"window": wid, "mode": mode, "samples": len(rs), "cpu_millicores": statistics.mean(cpu) if cpu else float("nan"),
                    "rss_mib": statistics.mean(rss) if rss else float("nan"), "net_bytes_per_s": net})
    return out

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------


def write_csv(path, rows):
    if not rows:
        return
    keys = list(rows[0].keys())
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: (fmt(v, 3) if isinstance(v, float) else v) for k, v in r.items()})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("campaign")
    ap.add_argument("--output", default="analysis/results/ladder")
    a = ap.parse_args()
    cdir = Path(a.campaign).resolve()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)

    plan = read_csv(cdir / "ladder-plan.csv")
    inventory, runs, partition_windows = [], [], []
    for p in plan:
        rdir = cdir / "runs" / p["run_id"]
        attempts = sorted(x.name for x in (cdir / "runs").glob(p["run_id"] + ".attempt-*"))
        status = "COMPLETE" if (rdir / "COMPLETE").exists() else ("ABORTED" if (rdir / "ABORTED").exists() else "NOT_STARTED")
        inventory.append({**p, "status": status, "earlier_attempts": len(attempts),
                          "abort_reason": read_text(rdir / "ABORTED") if status == "ABORTED" else ""})
        if status == "COMPLETE":
            row, windows = analyse_run(rdir)
            runs.append(row)
            if row["condition"] == "rp" and row["arm"] == "fa1":
                partition_windows.extend(windows)
    write_csv(out / "ladder-inventory.csv", inventory)
    write_csv(out / "ladder-runs.csv", runs)

    # Per-cell summary
    cells = []
    keys = sorted({(r["arm"], r["condition"], r["fault_seconds_planned"]) for r in runs},
                  key=lambda k: (k[1], int(k[2]), ARMS.index(k[0]) if k[0] in ARMS else 9))
    for arm, cond, dur in keys:
        rs = [r for r in runs if (r["arm"], r["condition"], r["fault_seconds_planned"]) == (arm, cond, dur)]
        n = len(rs)
        repl = sum(1 for r in rs if r["original_replaced"])
        lo, hi = clopper_pearson(repl, n)
        restored = [r["w2_nodeport_restored_s"] for r in rs]
        finite = [x for x in restored if not math.isnan(x) and not math.isinf(x)]
        never = sum(1 for x in restored if math.isinf(x))
        med = bca_median(finite) if finite else (float("nan"),) * 3
        clu = [r["clusterip_success_fraction"] for r in rs if not math.isnan(r.get("clusterip_success_fraction", float("nan")))]
        cells.append({
            "arm": arm, "condition": cond, "fault_seconds": dur, "runs": n,
            "replaced": repl, "replacement_rate": repl / n if n else float("nan"), "cp_low": lo, "cp_high": hi,
            "w2_restored_median_s": med[0], "w2_restored_bca_low": med[1], "w2_restored_bca_high": med[2],
            "w2_restored_p95_s": percentile(finite, 0.95) if len(finite) >= 2 else float("nan"),
            "never_restored_during_window": never,
            "clusterip_success_mean": statistics.mean(clu) if clu else float("nan"),
            "decisions": ";".join(sorted({r["decision"] for r in rs if r["decision"]})),
        })
    write_csv(out / "ladder-cells.csv", cells)

    verdicts = {}

    # H1: for each RP duration, FA1 replacement rate <= min of V0, T10, R2.
    h1_rows, h1_p = [], []
    for dur in sorted({c["fault_seconds"] for c in cells if c["condition"] == "rp"}, key=int):
        cell = {c["arm"]: c for c in cells if c["condition"] == "rp" and c["fault_seconds"] == dur}
        if "fa1" not in cell:
            continue
        fa = cell["fa1"]
        comps = [cell[k] for k in NATIVE_COMPARATORS_H1 if k in cell]
        best = min((c["replacement_rate"] for c in comps), default=float("nan"))
        holds = fa["replacement_rate"] <= best + 1e-12 if comps else None
        for c in comps:
            p = fisher_exact(fa["replaced"], fa["runs"] - fa["replaced"], c["replaced"], c["runs"] - c["replaced"])
            h1_rows.append({"fault_seconds": dur, "comparator": c["arm"], "fa1": f'{fa["replaced"]}/{fa["runs"]}',
                            "comparator_replaced": f'{c["replaced"]}/{c["runs"]}', "fisher_p": p})
            h1_p.append(p)
        verdicts.setdefault("H1_by_duration", {})[dur] = holds
    for r, adj in zip(h1_rows, holm(h1_p)):
        r["holm_p"] = adj
    write_csv(out / "h1-comparisons.csv", h1_rows)
    h1 = verdicts.get("H1_by_duration", {})
    verdicts["H1"] = "NOT TESTED" if not h1 else ("ACCEPTED" if all(h1.values()) else "REJECTED")

    # H2: FA1 median restoration within 15 s of T10; NX never restores during the fault.
    uw = {c["arm"]: c for c in cells if c["condition"] == "uw"}
    fa_uw = [r["w2_nodeport_restored_s"] for r in runs if r["arm"] == "fa1" and r["condition"] == "uw"]
    t10_uw = [r["w2_nodeport_restored_s"] for r in runs if r["arm"] == "t10" and r["condition"] == "uw"]
    nx_runs = [r for r in runs if r["arm"] == "nx" and r["condition"] == "uw"]
    nx_restored_in_fault = [r for r in nx_runs if not math.isnan(r["w2_nodeport_restored_s"]) and not math.isinf(r["w2_nodeport_restored_s"])
                            and r["w2_nodeport_restored_s"] < r["fault_seconds_measured"]]
    if "fa1" in uw and "t10" in uw:
        diff = uw["fa1"]["w2_restored_median_s"] - uw["t10"]["w2_restored_median_s"]
        fa_fin = [x for x in fa_uw if not math.isinf(x) and not math.isnan(x)]
        t10_fin = [x for x in t10_uw if not math.isinf(x) and not math.isnan(x)]
        verdicts["H2_detail"] = {
            "fa1_median_s": uw["fa1"]["w2_restored_median_s"], "t10_median_s": uw["t10"]["w2_restored_median_s"],
            "difference_s": diff, "cliffs_delta_fa1_vs_t10": cliffs_delta(fa_fin, t10_fin),
            "nx_runs": len(nx_runs), "nx_restored_during_fault": len(nx_restored_in_fault),
        }
        if math.isnan(diff):
            verdicts["H2"] = "INCONCLUSIVE"
        else:
            ok = (diff <= H2_MARGIN_S) and (len(nx_restored_in_fault) == 0)
            verdicts["H2"] = "ACCEPTED" if ok else "REJECTED"
    else:
        verdicts["H2"] = "NOT TESTED"

    # H4: probe grid.
    pg_rows, worst = analyse_probe_grid(cdir / "probe-grid")
    write_csv(out / "probe-grid.csv", pg_rows)
    if pg_rows:
        fr_ok = all(worst[(s, 3)][0] <= worst[(s, 3)][1] / 100 for s in ("healthy", "loss10") if (s, 3) in worst)
        fp_ok = worst.get(("down", 3), (1, 1))[0] == 0
        verdicts["H4"] = "ACCEPTED" if (fr_ok and fp_ok) else "REJECTED"
    else:
        verdicts["H4"] = "NOT TESTED"

    # H5: overhead equivalence.
    ow = analyse_overhead(cdir / "overhead")
    write_csv(out / "overhead-windows.csv", ow)
    fa_w = [w for w in ow if w["mode"] == "failure-aware"]
    na_w = [w for w in ow if w["mode"] == "native"]
    if len(fa_w) >= 2 and len(na_w) >= 2:
        cpu_up = one_sided_upper([w["cpu_millicores"] for w in fa_w])
        rss_up = one_sided_upper([w["rss_mib"] for w in fa_w])
        net_up = welch_upper([w["net_bytes_per_s"] for w in fa_w], [w["net_bytes_per_s"] for w in na_w])
        part_cpu_up = one_sided_upper([w[0] for w in partition_windows]) if len(partition_windows) >= 2 else float("nan")
        part_rss_up = one_sided_upper([w[1] for w in partition_windows]) if len(partition_windows) >= 2 else float("nan")
        verdicts["H5_detail"] = {
            "idle_windows_fa": len(fa_w), "idle_windows_native": len(na_w), "partition_windows": len(partition_windows),
            "idle_cpu_upper_m": cpu_up, "idle_rss_upper_mib": rss_up, "net_diff_upper_bps": net_up,
            "partition_cpu_upper_m": part_cpu_up, "partition_rss_upper_mib": part_rss_up,
        }
        checks = [cpu_up < BUDGET_CPU_M, rss_up < BUDGET_RSS_MIB, net_up < BUDGET_NET_BPS]
        if not math.isnan(part_cpu_up):
            checks += [part_cpu_up < BUDGET_CPU_M, part_rss_up < BUDGET_RSS_MIB]
        verdicts["H5"] = "ACCEPTED" if all(checks) else "REJECTED"
    else:
        verdicts["H5"] = "NOT TESTED"

    verdicts["campaign"] = cdir.name
    verdicts["seed"] = read_text(cdir / "seed.txt")
    verdicts["runs_planned"] = len(plan)
    verdicts["runs_completed"] = len(runs)
    verdicts["runs_aborted"] = sum(1 for i in inventory if i["status"] == "ABORTED")
    (out / "verdicts.json").write_text(json.dumps(verdicts, indent=2, default=str))
    print(json.dumps(verdicts, indent=2, default=str))


if __name__ == "__main__":
    main()
