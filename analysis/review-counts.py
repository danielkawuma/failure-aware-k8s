#!/usr/bin/env python3
"""Regenerate every count reported for the literature review.

Reads the coded review records in docs/review/ and recomputes the counts
stated in Sections III, V and VI of the manuscript (search totals, PRISMA
flow, re-screening outcome, second-coder agreement, taxonomy dimensions,
failure-handling dimension, Matrix 3 and Matrix 4 statements, RQ1).
Each count is compared with the value printed in the manuscript and
reported as PASS or FAIL. Exit status is 1 if any count fails.

Standard library only.

Usage:
    python3 analysis/review-counts.py [--review docs/review] [--output DIR]
"""

import argparse
import csv
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def kappa(pairs):
    n = len(pairs)
    p_o = sum(a == b for a, b in pairs) / n
    ca = Counter(a for a, _ in pairs)
    cb = Counter(b for _, b in pairs)
    p_e = sum(ca[k] * cb[k] for k in set(ca) | set(cb)) / n ** 2
    return (p_o - p_e) / (1 - p_e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--review", default=str(ROOT / "docs" / "review"))
    ap.add_argument("--output", default=str(ROOT / "analysis" / "results" / "review"))
    a = ap.parse_args()
    d = Path(a.review)

    search = read(d / "search-log.csv")
    screen = read(d / "screening-record.csv")
    health = read(d / "healthcare-screening.csv")
    second = read(d / "second-coder.csv")
    tags = read(d / "corpus-tags.csv")
    m3 = read(d / "matrix3-appraisal.csv")
    m4 = read(d / "matrix4-sovereignty.csv")

    checks = []

    def check(where, what, value, expected):
        ok = (round(value, 2) == expected) if isinstance(expected, float) else (value == expected)
        checks.append({"section": where, "statement": what, "computed": value,
                       "manuscript": expected, "status": "PASS" if ok else "FAIL"})

    # Search totals (Section III and Fig. PRISMA)
    def hits(stream, db=None):
        return sum(int(r["raw_hits"]) for r in search
                   if r["stream"] == stream and (db is None or r["database"] == db))
    check("III", "primary search records", hits("primary"), 3800)
    check("III", "IEEE Xplore records", hits("primary", "IEEE Xplore"), 383)
    check("III", "ACM Digital Library records", hits("primary", "ACM Digital Library"), 949)
    check("III", "ScienceDirect records", hits("primary", "ScienceDirect"), 374)
    check("III", "Google Scholar records", hits("primary", "Google Scholar"), 2094)
    check("III", "healthcare stream records", hits("healthcare"), 42450)
    check("III", "healthcare IEEE Xplore strings (excluding healthcare cloud computing)",
          sum(int(r["raw_hits"]) for r in search if r["stream"] == "healthcare"
              and r["database"] == "IEEE Xplore" and r["query_as_run"].strip() != "healthcare cloud computing"), 2080)

    # Screening (Section III)
    check("III", "full-text candidates", len(screen), 58)
    orig = Counter(r["original_decision"] for r in screen)
    check("III", "originally included", orig["Include"], 25)
    oc = Counter(r["original_code"] for r in screen if r["original_decision"] == "Exclude")
    check("III", "original E1", oc["E1"], 11)
    check("III", "original E2", oc["E2"], 1)
    check("III", "original E3", oc["E3"], 3)
    check("III", "original scope", oc["SCOPE"], 18)
    check("III", "decisions changed by re-screening", sum(r["change"] == "decision changed" for r in screen), 5)
    check("III", "codes changed by re-screening", sum(r["change"] == "code changed" for r in screen), 3)
    inc = [r for r in screen if r["decision"] == "Include"]
    check("III", "included after re-screening", len(inc), 24)
    nc = Counter(r["code"] for r in screen if r["decision"] == "Exclude")
    check("III", "excluded E1", nc["E1"], 11)
    check("III", "excluded E2", nc["E2"], 2)
    check("III", "excluded E3", nc["E3"], 5)
    check("III", "excluded scope", nc["SCOPE"], 16)
    hc = Counter(r["code"] for r in health)
    check("III", "healthcare full texts", len(health), 7)
    check("III", "healthcare E1", hc["E1"], 5)
    check("III", "healthcare E3", hc["E3"], 1)
    check("III", "healthcare scope", hc["SCOPE"], 1)

    # Second coder
    first = {r["paper_id"]: r for r in screen}
    pairs = [(first[r["paper_id"]]["decision"], r["decision"]) for r in second]
    check("III", "second-coder sample size", len(second), 12)
    check("III", "decision agreement", sum(x == y for x, y in pairs), 10)
    check("III", "Cohen's kappa", round(kappa(pairs), 2), 0.64)
    both = [(first[r["paper_id"]]["code"], r["code"]) for r in second
            if r["decision"] == "Exclude" and first[r["paper_id"]]["decision"] == "Exclude"]
    check("III", "code agreement where both excluded", sum(x == y for x, y in both), 6)
    check("III", "both excluded", len(both), 7)

    # Corpus consistency: tags cover exactly the included studies
    tagged = {r["paper_id"] for r in tags}
    check("III", "coded studies equal included studies", tagged == {r["paper_id"] for r in inc}, True)
    roles = Counter(r["role"] for r in tags)
    check("III", "design precedent", roles["precedent"], 21)
    check("III", "context role", roles["context"], 3)

    # Section V taxonomy
    check("V", "D1 OS-level containers", sum(r["d1_substrate"] == "os-container" for r in tags), 20)
    check("V", "D1 other substrates", sum(r["d1_substrate"] != "os-container" for r in tags), 4)
    d3 = Counter(r["d3_mechanism"] for r in tags)
    check("V", "D3 fixed-rule", d3["fixed-rule"], 10)
    check("V", "D3 learned", d3["learned"], 3)
    check("V", "D3 deterministic coordination", d3["deterministic coordination"], 3)
    check("V", "D3 closed control loop", d3["closed control loop"], 2)
    d5 = Counter(r["d5_scaling"] for r in tags)
    check("V", "D5 failure-triggered", d5["failure-triggered"], 5)
    check("V", "D5 predictive", d5["predictive"], 4)
    check("V", "D5 adaptive", d5["adaptive"], 3)
    check("V", "D5 N/A", d5["N/A"], 9)
    check("V", "failure handling: inject a partition", sum(r["injects_partition"] == "yes" for r in tags), 5)
    check("V", "failure handling: compare partition and crash", sum(r["compares_partition_and_crash"] == "yes" for r in tags), 2)
    check("V", "failure handling: post-suspicion check", sum(r["post_suspicion_check"] == "yes" for r in tags), 4)
    check("V", "failure handling: exclude previous authority", sum(r["excludes_previous_authority"] == "yes" for r in tags), 2)
    fi = Counter(r["fault_injection"] for r in tags)
    check("V", "no fault injection", fi["none"], 5)
    check("V", "pressure induced by workload", fi["induced by workload"], 1)
    check("V", "fault parameters not reported", fi["parameters not reported"], 1)

    # Matrix 3 and Matrix 4 statements (supplement, Section VI)
    check("S1", "averages fallacy present or partial", sum(r["Averages fallacy"] in ("Y", "P") for r in m3), 12)
    check("S1", "Matrix 3 rows", len(m3), 24)
    cols = ["Offline autonomy", "Bandwidth/egress", "Data residency", "Hardware efficiency"]
    all4 = [r["citation_key"] for r in m4 if all(int(r[c]) >= 4 for c in cols)]
    check("S1", "only rodriguez2026arapo scores 4+ on all four", all4, ["rodriguez2026arapo"])
    res = sorted(r["citation_key"] for r in m4 if int(r["Data residency"]) > 3)
    check("S1", "data residency above 3", res, ["li2026pyramid", "rodriguez2026arapo"])
    hw5 = [r["citation_key"] for r in m4 if int(r["Hardware efficiency"]) == 5]
    check("S1", "hardware efficiency 5", hw5, ["kwon2026erpf"])

    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "review-counts.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(checks[0].keys()))
        w.writeheader()
        for c in checks:
            w.writerow({k: json.dumps(v) if isinstance(v, (list, bool)) else v for k, v in c.items()})

    width = max(len(c["statement"]) for c in checks)
    for c in checks:
        print(f'{c["status"]}  {c["section"]:3} {c["statement"]:<{width}}  {c["computed"]}')
    failed = sum(c["status"] == "FAIL" for c in checks)
    print(f"\nREVIEW_COUNTS: {len(checks) - failed}/{len(checks)} PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
