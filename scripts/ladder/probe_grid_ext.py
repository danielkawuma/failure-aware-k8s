#!/usr/bin/env python3
"""Extended probe grid: same probes, classifier and trial design as
probe_grid.py on additional reachable states. "healthy" and "down" stay
defined for the self-test; the plan contains only the new states."""
import argparse, csv, random, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe_grid as pg  # noqa: E402
NEW = {"delay500": "delay 500ms", "delay1000": "delay 1000ms", "delay1500": "delay 1500ms",
       "loss70": "loss 70%", "loss90": "loss 90%"}
pg.STATES = {"healthy": None, "down": "loss 100%", **NEW}
pg.GROUND_TRUTH = {s: ("unreachable" if s == "down" else "reachable") for s in pg.STATES}
if __name__ == "__main__":
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--output", required=True); p.add_argument("--seed", type=int, required=True)
    p.add_argument("--trials", type=int, default=100)
    a, _ = p.parse_known_args()
    out = Path(a.output); out.mkdir(parents=True, exist_ok=True)
    plan = out / "plan.csv"
    if not plan.exists():
        order = [s for s in NEW for _ in range(a.trials)]
        random.Random(a.seed + 4).shuffle(order)
        with plan.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["trial", "state"]); w.writeheader()
            w.writerows({"trial": f"{i:04d}", "state": s} for i, s in enumerate(order, 1))
    pg.main()
