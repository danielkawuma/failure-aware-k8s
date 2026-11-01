#!/usr/bin/env bash
# Top-up campaigns for the Midterm Test 2 resubmission, run one after another:
#   1. Ladder top-up: V0, T10, NX, R2, FA1 at the 600-s reachable partition and
#      the 480-s unreachable workload, 5 more runs per cell (50 runs), in a new
#      seeded campaign directory.
#   2. Extended probe grid: delays of 0.5, 1.0, 1.5 s and reply loss of 70 and
#      90 %, 100 trials each (500 trials), in the top-up campaign directory.
#   3. Live writer: 10 more fenced runs, in a new seeded campaign directory.
#   4. OpenMRS Scenario B under clinical load (V0, T10, FA1; 3 runs each), only
#      if OPENMRS_PASS is set and the gateway answers.
# Each stage is skipped if its DONE marker exists, so the script can be
# restarted after an interruption. The main campaign directory is not touched;
# CURRENT is pointed back at it at the end. Log: ~/topup.log
#
#   export SSH_KEY=~/.ssh/k8s-aware
#   export OPENMRS_USER=admin OPENMRS_PASS='...' OPENMRS_BASE_URL=http://<worker2-ip>:30366/openmrs   # optional
#   bash scripts/run-topup-campaigns.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO"
LOG="$HOME/topup.log"; exec > >(tee -a "$LOG") 2>&1
say() { printf '[TOPUP %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
[[ -f "${SSH_KEY:-}" ]] || { say "SSH_KEY not set to an existing key file"; exit 1; }
source scripts/experiment-config.sh
LADDER_ROOT="$REPO/experiments/evaluation/ladder"
MAIN="campaign-20261029T101038Z"
STATE="$REPO/experiments/evaluation/topup"; mkdir -p "$STATE"
busy() { pgrep -f 'campaign.sh' >/dev/null; }
while busy; do say "Another campaign is running; waiting"; sleep 60; done
"$REPO/scripts/fault.sh" clear-all || true

# 1. Ladder top-up
if [[ ! -f "$STATE/ladder.DONE" ]]; then
    rm -f "$LADDER_ROOT/CURRENT"
    say "Stage 1: ladder top-up (RP 600 s and UW 480 s, 5 per cell, 50 runs)"
    ARMS="v0 t10 nx r2 fa1" RP_DURATIONS="600" UW_HOLD_SECONDS=480 REPS=3 scripts/ladder/campaign.sh ladder
    d="$(readlink -f "$LADDER_ROOT/CURRENT")"; echo "$d" > "$STATE/ladder.path"
    say "Stage 1 done in $d: $(find "$d/runs" -maxdepth 2 -name COMPLETE | wc -l) complete, $(find "$d/runs" -maxdepth 2 -name ABORTED | wc -l) aborted"
    touch "$STATE/ladder.DONE"
fi

# 2. Extended probe grid
if [[ ! -f "$STATE/probe.DONE" ]]; then
    d="$(cat "$STATE/ladder.path")"; out="$d/probe-grid-ext"; mkdir -p "$out"
    say "Stage 2: extended probe grid into $out"
    "$REPO/scripts/fault.sh" clear-all || true
    kubectl -n failure-aware delete deployment baseline-web --ignore-not-found --wait=true --timeout=120s >/dev/null || true
    kubectl -n failure-aware delete pdb baseline-web --ignore-not-found >/dev/null 2>&1 || true
    sleep 10
    kubectl apply -f workloads/ladder/nginx-nx.yaml >/dev/null
    kubectl -n failure-aware rollout status deployment/baseline-web --timeout=180s
    for i in $(seq 1 60); do curl -fsS -m 3 -o /dev/null "http://${WORKER1_IP}:${NODEPORT}/" && break; sleep 2; done
    python3 scripts/ladder/probe_grid_ext.py --output "$out" --seed "$(cat "$d/seed.txt")" --trials 100 \
        --url "http://${WORKER1_IP}:${NODEPORT}/" --nodeport "${NODEPORT}" --ssh-key "${SSH_KEY}" --ssh-target "${WORKER1_SSH}" \
        && { date -u +%FT%TZ > "$out/COMPLETE"; touch "$STATE/probe.DONE"; say "Stage 2 done"; } \
        || say "Stage 2 FAILED (exit $?); continuing"
    "$REPO/scripts/fault.sh" clear-all || true
fi

# 3. Live writer, fenced
if [[ ! -f "$STATE/livewriter.DONE" ]]; then
    say "Stage 3: live writer, 10 fenced runs"
    LW_ARMS=fenced RUNS_PER_ARM=10 scripts/live-writer/campaign.sh run
    d="$(readlink -f "$REPO/experiments/evaluation/live-writer/CURRENT")"; echo "$d" > "$STATE/livewriter.path"
    say "Stage 3 done in $d: $(find "$d/runs" -maxdepth 2 -name COMPLETE | wc -l) complete, $(find "$d/runs" -maxdepth 2 -name fence-verified-time.txt | wc -l) fence-verified, $(find "$d/runs" -maxdepth 2 -name ABORTED | wc -l) aborted"
    touch "$STATE/livewriter.DONE"
fi

# 4. OpenMRS under load (optional)
if [[ ! -f "$STATE/load.DONE" && -n "${OPENMRS_PASS:-}" && -n "${OPENMRS_BASE_URL:-}" ]]; then
    say "Stage 4: OpenMRS Scenario B under load (V0, T10, FA1; 3 runs each)"
    MODES=V0,T10,FA1 RUNS_PER_MODE=3 START_RUN=101 FAULT_SECONDS=600 \
        bash scripts/openmrs/load/run-openmrs-load-campaign.sh && touch "$STATE/load.DONE" || say "Stage 4 FAILED (exit $?)"
fi

ln -sfn "$MAIN" "$LADDER_ROOT/CURRENT"
"$REPO/scripts/fault.sh" clear-all || true
say "All stages finished."
