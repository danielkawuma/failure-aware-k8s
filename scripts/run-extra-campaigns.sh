#!/usr/bin/env bash
# ============================================================
# Additional campaigns (docs/hypotheses-addendum-2.md), run in sequence
# on the runner host:
#
#   1. kh      kubelet hang: V0, T10, FA1, 5 runs each, 480-s hang
#   2. fl      flapping link: V0, T10, FA1, 5 runs each, 600 s of
#              75 s down / 30 s up cycles of the Scenario B rule
#   3. ladder  top-up of the baseline ladder: 2 more runs per cell
#              (V0, T10, NX, R2, FA1 x reachable 120 s, 600 s and
#              unreachable 480 s = 30 runs)
#   4. lw      live-writer fencing: 20 more fenced runs
#
# Every stage is resumable: re-running this script continues the
# stage's own campaign and skips completed runs. No new run starts
# after STOP_AT_UTC (ladder stages) or LW_START_BY_UTC (live writer),
# so the last run ends before the morning.
#
# Usage (on the runner host, inside tmux):
#   export SSH_KEY=~/.ssh/<key>
#   export PREREG_COMMIT=<hash of the commit that adds the addendum>
#   bash scripts/run-extra-campaigns.sh
# Progress:  tail -f ~/extra.log
# ============================================================

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"

: "${SSH_KEY:?export SSH_KEY first}"
: "${PREREG_COMMIT:?export PREREG_COMMIT (the addendum commit) first}"
export SSH_KEY PREREG_COMMIT
source scripts/experiment-config.sh

LOG="${HOME}/extra.log"
exec > >(tee -a "${LOG}") 2>&1
say() { echo "[EXTRA $(date -u +%T)Z] $*"; }

STOP_AT_UTC="${STOP_AT_UTC:-tomorrow 05:00}"        # 08:00 EAT
LW_START_BY_UTC="${LW_START_BY_UTC:-tomorrow 04:30}" # 07:30 EAT
STOP_AT_EPOCH="$(TZ=UTC date -d "${STOP_AT_UTC}" +%s)"
LW_START_BY_EPOCH="$(TZ=UTC date -d "${LW_START_BY_UTC}" +%s)"
export STOP_AT_EPOCH

LR="${REPO}/experiments/evaluation/ladder"
LW="${REPO}/experiments/evaluation/live-writer"
MAIN_LADDER="$(readlink "${LR}/CURRENT" 2>/dev/null || echo campaign-20261029T101038Z)"

w1_ready() {
    local i
    for i in $(seq 1 40); do
        if kubectl get node "${WORKER1_NODE}" --no-headers 2>/dev/null | grep -q " Ready" &&
           ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 "${WORKER1_SSH}" true 2>/dev/null; then
            return 0
        fi
        sleep 30
    done
    say "Worker1 not Ready after 20 min"
    return 1
}

past_stop() { (( $(date +%s) >= STOP_AT_EPOCH )); }

# ---------------- 0. Stability check ----------------
say "start; prereg=${PREREG_COMMIT}; ladder stop $(TZ=UTC date -d @"${STOP_AT_EPOCH}" +%FT%TZ); live-writer start-by $(TZ=UTC date -d @"${LW_START_BY_EPOCH}" +%FT%TZ)"
kubectl -n openmrs37 scale deploy --all --replicas=0 >/dev/null 2>&1 || true
bash scripts/fault.sh clear-all || { sleep 30; bash scripts/fault.sh clear-all || true; }
ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 "${WORKER1_SSH}" \
    "sudo -n systemctl start k3s-agent; uptime; systemctl is-active k3s-agent; systemctl show k3s-agent -p KillMode; pgrep -a mariadbd || echo 'no mariadbd'" \
    || { say "Worker1 not reachable over SSH; stopping"; exit 1; }
w1_ready || exit 1
kubectl get nodes -o wide
say "controller binary sha256: $(sha256sum "${CONTROLLER_BINARY}" | cut -d' ' -f1)"
for f in $(find "${LR}" -name controller-binary.sha256 2>/dev/null | sort | tail -n 1); do
    say "last recorded overhead binary: $(cut -d' ' -f1 "${f}") (${f#"${REPO}"/})"
done

# Run a ladder-type stage in its own campaign. Arguments: stage name,
# then environment assignments for scripts/ladder/campaign.sh.
ladder_stage() {
    local name="$1"; shift
    local pathfile="${LR}/extra-${name}.path"
    if past_stop; then say "stage ${name}: stop time reached, skipped"; return 0; fi
    w1_ready || return 1
    if [[ -f "${pathfile}" ]]; then
        ln -sfn "$(basename "$(cat "${pathfile}")")" "${LR}/CURRENT"
        say "stage ${name}: resuming $(cat "${pathfile}")"
    else
        rm -f "${LR}/CURRENT"
        say "stage ${name}: new campaign"
    fi
    env "$@" scripts/ladder/campaign.sh ladder
    local rc=$? d
    d="$(readlink -f "${LR}/CURRENT")"
    echo "${d}" > "${pathfile}"
    echo "${PREREG_COMMIT}" > "${d}/preregistration-commit.txt"
    say "stage ${name} ended (exit ${rc}) in ${d#"${REPO}"/}: $(find "${d}/runs" -maxdepth 2 -name COMPLETE | wc -l) complete, $(find "${d}/runs" -maxdepth 2 -name ABORTED | wc -l) aborted, plan $(( $(wc -l < "${d}/ladder-plan.csv") - 1 ))"
    ln -sfn "${MAIN_LADDER}" "${LR}/CURRENT"
    bash scripts/fault.sh clear-all >/dev/null 2>&1 || true
    ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 "${WORKER1_SSH}" "sudo -n systemctl start k3s-agent" >/dev/null 2>&1 || true
    (( rc == 130 || rc == 143 )) && exit "${rc}"
    return 0
}

# ---------------- 1. Kubelet hang ----------------
ladder_stage kh ARMS="v0 t10 fa1" RP_DURATIONS="" UW_HOLD_SECONDS=0 KH_SECONDS=480 FL_SECONDS=0 REPS=5

# ---------------- 2. Flapping link ----------------
ladder_stage fl ARMS="v0 t10 fa1" RP_DURATIONS="" UW_HOLD_SECONDS=0 KH_SECONDS=0 FL_SECONDS=600 \
    FL_DOWN_SECONDS=75 FL_UP_SECONDS=30 REPS=5

# ---------------- 3. Ladder top-up ----------------
ladder_stage topup ARMS="v0 t10 nx r2 fa1" RP_DURATIONS="120 600" UW_HOLD_SECONDS=480 KH_SECONDS=0 FL_SECONDS=0 REPS=2

# ---------------- 4. Live writer, 20 more fenced runs ----------------
# The campaign script gains a start-by check, so no run starts after
# LW_START_BY_UTC; a run already started always finishes its retirement.
if ! grep -q STOP_AT_EPOCH scripts/live-writer/campaign.sh; then
    python3 - scripts/live-writer/campaign.sh <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
a = '''        [[ -f "${dir}/runs/${run_id}/COMPLETE" ]] && continue
        rc=0'''
b = '''        [[ -f "${dir}/runs/${run_id}/COMPLETE" ]] && continue
        if [[ -n "${STOP_AT_EPOCH:-}" ]] && (( $(date +%s) >= STOP_AT_EPOCH )); then
            log "Start-by time reached; no new run started"
            break
        fi
        rc=0'''
assert t.count(a) == 1, "live-writer patch point not found"
open(p, "w").write(t.replace(a, b))
PY
fi
if (( $(date +%s) < LW_START_BY_EPOCH )); then
    w1_ready || exit 1
    lwpath="${LW}/extra-lw.path"
    if [[ -f "${lwpath}" ]]; then
        ln -sfn "$(basename "$(cat "${lwpath}")")" "${LW}/CURRENT"
        say "stage lw: resuming $(cat "${lwpath}")"
    else
        rm -f "${LW}/CURRENT"
        say "stage lw: new campaign, 20 fenced runs"
    fi
    STOP_AT_EPOCH="${LW_START_BY_EPOCH}" LW_ARMS=fenced RUNS_PER_ARM=20 scripts/live-writer/campaign.sh run
    rc=$?
    d="$(readlink -f "${LW}/CURRENT")"
    echo "${d}" > "${lwpath}"
    echo "${PREREG_COMMIT}" > "${d}/preregistration-commit.txt"
    say "stage lw ended (exit ${rc}) in ${d#"${REPO}"/}: $(find "${d}/runs" -maxdepth 2 -name COMPLETE | wc -l) complete"
    if (( rc != 0 )); then
        say "live writer stopped for inspection; the fence and Pods are left as they are. Do not unfence before checking Worker1."
        exit 1
    fi
else
    say "stage lw: start-by time reached, skipped"
fi

bash scripts/fault.sh clear-all >/dev/null 2>&1 || true
say "ALL DONE"
