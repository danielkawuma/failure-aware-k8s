#!/usr/bin/env python3
"""Probe error-rate grid for the Failure-Aware verification rule (H4).

Each trial makes five HTTP attempts against the workload's NodePort on
Worker1, from the same vantage point as the controller, with the
controller's parameters: 3 s timeout per attempt and 0.5 s between
attempts. The outcome for k = 1, 3 and 5 attempts is the classification
of the first k attempts by the controller's rule
(controller/src/awareness.rs, classify_operational_state):

    successes > failures             -> reachable  (PRESERVE)
    successes == 0 and failures > 0  -> unreachable (RECOVER path)
    otherwise                        -> indeterminate (PRESERVE)

The workload state is set on Worker1 before each trial with tc/netem on
egress traffic whose source port is the NodePort, so only the workload's
replies are affected; the control-plane path and SSH are untouched.

States (ground truth in brackets):
    healthy     no impairment                [reachable]
    loss10/30/50  reply loss of 10/30/50 %   [reachable]
    delay2500   2.5 s added reply delay      [reachable]
    down        100 % reply loss             [unreachable]

Trials of all states are interleaved in a seeded random order.
"""

import argparse
import csv
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

STATES = {
    "healthy": None,
    "loss10": "loss 10%",
    "loss30": "loss 30%",
    "loss50": "loss 50%",
    "delay2500": "delay 2500ms",
    "down": "loss 100%",
}
GROUND_TRUTH = {s: ("unreachable" if s == "down" else "reachable") for s in STATES}

ATTEMPTS = 5
TIMEOUT_S = 3.0
INTERVAL_S = 0.5


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class Remote:
    def __init__(self, key, target, nodeport):
        self.key = key
        self.target = target
        self.nodeport = nodeport
        self.iface = None

    def run(self, command, check=True):
        result = subprocess.run(
            ["ssh", "-i", self.key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
             self.target, command],
            capture_output=True, text=True, timeout=60,
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"remote command failed: {command}\n{result.stderr}")
        return result.stdout.strip()

    def interface(self):
        if self.iface is None:
            self.iface = self.run("ip route show default | awk 'NR==1 {print $5}'")
            if not self.iface:
                raise RuntimeError("could not determine Worker1 interface")
        return self.iface

    def clear(self):
        self.run(f"sudo -n tc qdisc del dev {self.interface()} root 2>/dev/null || true", check=False)

    def apply(self, state):
        self.clear()
        netem = STATES[state]
        if netem is None:
            return
        i = self.interface()
        self.run(
            f"sudo -n tc qdisc add dev {i} root handle 1: prio && "
            f"sudo -n tc qdisc add dev {i} parent 1:3 handle 30: netem {netem} && "
            f"sudo -n tc filter add dev {i} protocol ip parent 1:0 prio 3 u32 "
            f"match ip sport {self.nodeport} 0xffff flowid 1:3"
        )

    def show(self):
        return self.run(f"tc qdisc show dev {self.interface()}", check=False)


def attempt(url):
    """One attempt with a total deadline of 3 s, as the controller's
    HTTP client applies (reqwest total timeout), using curl."""
    start = time.monotonic()
    result = subprocess.run(
        ["curl", "--silent", "--output", "/dev/null", "--max-time", str(TIMEOUT_S),
         "--write-out", "%{http_code}", url],
        capture_output=True, text=True,
    )
    latency = (time.monotonic() - start) * 1000
    code = int(result.stdout.strip() or 0)
    ok = result.returncode == 0 and 200 <= code < 300
    error = "" if ok else f"curl_exit_{result.returncode}"
    return ok, code, latency, error


def classify(results):
    successes = sum(1 for r in results if r)
    failures = len(results) - successes
    if successes > failures:
        return "reachable"
    if successes == 0 and failures > 0:
        return "unreachable"
    return "indeterminate"


def self_test(remote, url):
    """Confirm that the impairment reaches the probe and is removed."""
    remote.apply("down")
    time.sleep(1)
    down_ok = [attempt(url)[0] for _ in range(3)]
    remote.apply("healthy")
    time.sleep(2)
    up_ok = [attempt(url)[0] for _ in range(3)]
    return (not any(down_ok)) and all(up_ok), down_ok, up_ok


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--output", required=True)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--trials", type=int, default=100)
    p.add_argument("--url", required=True)
    p.add_argument("--nodeport", type=int, required=True)
    p.add_argument("--ssh-key", required=True)
    p.add_argument("--ssh-target", required=True)
    a = p.parse_args()

    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    remote = Remote(a.ssh_key, a.ssh_target, a.nodeport)

    passed, down_ok, up_ok = self_test(remote, a.url)
    (out / "self-test.txt").write_text(
        f"utc={utc_now()}\ninterface={remote.interface()}\n"
        f"down_attempt_success={down_ok}\nhealthy_attempt_success={up_ok}\n"
        f"passed={passed}\n"
    )
    if not passed:
        remote.clear()
        print("Self-test failed: the impairment does not affect the probe path", file=sys.stderr)
        sys.exit(1)

    plan_path = out / "plan.csv"
    if plan_path.exists():
        plan = [row for row in csv.DictReader(plan_path.open())]
    else:
        rng = random.Random(a.seed + 4)
        order = [s for s in STATES for _ in range(a.trials)]
        rng.shuffle(order)
        plan = [{"trial": f"{i:04d}", "state": s} for i, s in enumerate(order, 1)]
        with plan_path.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["trial", "state"])
            w.writeheader()
            w.writerows(plan)

    attempts_path = out / "attempts.csv"
    trials_path = out / "trials.csv"
    done = set()
    if trials_path.exists():
        done = {row["trial"] for row in csv.DictReader(trials_path.open())}

    new_attempts = not attempts_path.exists()
    new_trials = not trials_path.exists()
    fa = attempts_path.open("a", newline="")
    ft = trials_path.open("a", newline="")
    wa = csv.writer(fa)
    wt = csv.writer(ft)
    if new_attempts:
        wa.writerow(["trial", "state", "attempt", "timestamp_utc", "success", "status", "latency_ms", "error"])
    if new_trials:
        wt.writerow(["trial", "state", "ground_truth", "attempt_successes",
                     "class_k1", "class_k3", "class_k5", "timestamp_utc"])

    current = None
    try:
        for n, row in enumerate(plan, 1):
            trial, state = row["trial"], row["state"]
            if trial in done:
                continue
            if state != current:
                remote.apply(state)
                current = state
                time.sleep(1)
            started = utc_now()
            results = []
            for k in range(1, ATTEMPTS + 1):
                ok, status, latency, err = attempt(a.url)
                results.append(ok)
                wa.writerow([trial, state, k, utc_now(), ok, status, f"{latency:.3f}", err])
                if k < ATTEMPTS:
                    time.sleep(INTERVAL_S)
            wt.writerow([trial, state, GROUND_TRUTH[state], "".join("1" if r else "0" for r in results),
                         classify(results[:1]), classify(results[:3]), classify(results[:5]), started])
            fa.flush()
            ft.flush()
            if n % 50 == 0:
                print(f"[PROBE GRID] {n}/{len(plan)} trials", flush=True)
    finally:
        remote.clear()
        fa.close()
        ft.close()
        (out / "qdisc-after.txt").write_text(remote.show() + "\n")


if __name__ == "__main__":
    main()
