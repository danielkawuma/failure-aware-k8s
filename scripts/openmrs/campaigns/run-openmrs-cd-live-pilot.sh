#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

export SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

BASE="$ROOT/experiments/evaluation/openmrs/scenario-c-d"
RUN="$BASE/pilot-$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$RUN"

exec > >(tee -a "$RUN/pilot.log") 2>&1

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

[[ "${OPENMRS_CD_ACK_COLLATERAL_IMPACT:-false}" == true ]] ||
    fail "Collateral-impact acknowledgment required"

[[ "${OPENMRS_CD_ACK_LIVE_WRITER_RISK:-false}" == true ]] ||
    fail "Live-writer-risk acknowledgment required"

CONTROLLER="$ROOT/controller/target/debug/failure-aware-controller"

[[ -x "$CONTROLLER" ]] ||
    fail "Controller binary missing"

python3 "$ROOT/scripts/openmrs-cd-prepare.py" \
    "$RUN/controller.json"

read -r ORIGINAL IP CANDIDATE POD_IP < <(
    python3 - "$RUN/controller-authority.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    x = json.load(f)

print(x["node"], x["ip"], x["candidate"], x["pod_ip"])
PY
)

[[ "$ORIGINAL" != "$CANDIDATE" ]] ||
    fail "Candidate equals original worker"

VERIFIER_NODE="${OPENMRS_CD_VERIFIER_NODE:-$CANDIDATE}"

[[ "$VERIFIER_NODE" != "$ORIGINAL" ]] ||
    fail "Verifier cannot be original worker"

VERIFIER_IP="$(
    kubectl get node "$VERIFIER_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
)"

[[ -n "$VERIFIER_IP" ]] ||
    fail "Verifier IP unavailable"

NS="${OPENMRS_CD_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_CD_DEPLOYMENT:-openmrs-mariadb}"
SEL="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"

SELECTOR="$(
    kubectl get deployment "$DEP" -n "$NS" \
        -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}'
)"

[[ -z "$SELECTOR" ]] ||
    fail "Deployment remains pinned to $SELECTOR"

export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL"
export OPENMRS_CD_ORIGINAL_IP="$IP"

FENCE="$ROOT/scripts/openmrs-cd-fence-original.sh"

# Storage fence must be positively inactive before fault.
set +e
"$FENCE" status > "$RUN/initial-fence.log" 2>&1
FENCE_RC=$?
set -e

[[ "$FENCE_RC" -eq 1 ]] ||
    fail "Storage fence not verified inactive"

grep -qx NOT_FENCED "$RUN/initial-fence.log" ||
    fail "Ambiguous storage fence"

remote() {
    timeout 30 ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "ubuntu@$IP" \
        "sudo -n /usr/local/sbin/openmrs-cd-fault $1 $POD_IP"
}

# Explicit fault-status contract.
set +e
remote status > "$RUN/initial-fault.log" 2>&1
FAULT_RC=$?
set -e

[[ "$FAULT_RC" -eq 1 ]] ||
    fail "Fault status not INACTIVE"

grep -qx INACTIVE "$RUN/initial-fault.log" ||
    fail "Ambiguous remote fault state"

log "Initial fault and storage fence verified inactive"

PROBE_PID=""
RECOVERY_PROBE_PID=""
CONTROLLER_PID=""
FAULT_ATTEMPTED=false
FAULT_CLEARED=false

cleanup() {
    local rc=$?

    trap - EXIT INT TERM
    set +e

    if [[ "$FAULT_ATTEMPTED" == true &&
          "$FAULT_CLEARED" != true ]]; then
        remote clear > "$RUN/emergency-fault-clear.log" 2>&1
    fi

    for pid in \
        "$CONTROLLER_PID" \
        "$RECOVERY_PROBE_PID" \
        "$PROBE_PID"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done

    kubectl get pods -n "$NS" -l "$SEL" -o wide \
        > "$RUN/final-pods.txt" 2>&1

    "$FENCE" status > "$RUN/final-fence.log" 2>&1

    # Never automatically remove the NFS fence.
    echo "NFS fence retained pending independent reconciliation"

    if (( rc == 0 )); then
        touch "$RUN/OBSERVATION_COMPLETE"
    else
        touch "$RUN/INCOMPLETE"
    fi

    log "Results: $RUN (exit=$rc)"
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 "$ROOT/scripts/openmrs-db-probe.py" \
    --host "$POD_IP" \
    --port "${OPENMRS_DB_PORT:-3306}" \
    --verifier-host "$VERIFIER_IP" \
    --ssh-key "$SSH_KEY" \
    --http-port "${OPENMRS_DB_PROBE_HTTP_PORT:-18086}" \
    > "$RUN/db-probe.log" 2>&1 &

PROBE_PID=$!

sleep 2

PROBE_URL="http://127.0.0.1:${OPENMRS_DB_PROBE_HTTP_PORT:-18086}"

probe_state() {
    curl -fsS --max-time 12 "$PROBE_URL/state" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["state"])'
}

PRE_STATE="$(probe_state)" ||
    fail "Independent verifier unavailable"

[[ "$PRE_STATE" == REACHABLE ]] ||
    fail "Original database not reachable before fault"

RECOVERY_PORT="${OPENMRS_CD_RECOVERY_PROBE_PORT:-18087}"

python3 "$ROOT/scripts/openmrs-recovery-probe.py" \
    --namespace "$NS" \
    --selector "$SEL" \
    --original-node "$ORIGINAL" \
    --candidate-node "$CANDIDATE" \
    --verifier-host "$VERIFIER_IP" \
    --ssh-key "$SSH_KEY" \
    --http-port "$RECOVERY_PORT" \
    > "$RUN/recovery-probe.log" 2>&1 &

RECOVERY_PROBE_PID=$!

sleep 2

kill -0 "$RECOVERY_PROBE_PID" ||
    fail "Recovery verifier exited"

FAILURE_AWARE_RECOVERY_VERIFY_URL="http://127.0.0.1:$RECOVERY_PORT/health" \
FAILURE_AWARE_RECOVERY_TIMEOUT_MS=1200000 \
FAILURE_AWARE_FENCING_TIMEOUT_MS=120000 \
FAILURE_AWARE_CONTROLLER_CONFIG="$RUN/controller.json" \
"$CONTROLLER" > "$RUN/controller.log" 2>&1 &

CONTROLLER_PID=$!

sleep 10

kill -0 "$CONTROLLER_PID" ||
    fail "Controller exited before fault"

log "Applying Scenario C+D fault"

FAULT_ATTEMPTED=true

remote apply > "$RUN/fault-apply.log" 2>&1 ||
    fail "Fault application failed"

grep -qx ACTIVE "$RUN/fault-apply.log" ||
    fail "Fault application not positively verified"

date -u +%Y-%m-%dT%H:%M:%S.%NZ \
    > "$RUN/fault-time.txt"

ISOLATED=false

for attempt in 1 2 3 4 5; do
    STATE="$(probe_state)" ||
        fail "Independent verifier transport failed"

    printf '%s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
        "$STATE" >> "$RUN/probe-states.log"

    [[ "$STATE" != UNKNOWN ]] ||
        fail "Independent verifier returned UNKNOWN"

    if [[ "$STATE" == UNREACHABLE ]]; then
        ISOLATED=true
        break
    fi

    sleep 2
done

[[ "$ISOLATED" == true ]] ||
    fail "Database did not become unreachable"

log "Independent database unreachability verified"

END=$((SECONDS + ${OPENMRS_CD_OBSERVE_SECONDS:-900}))

while (( SECONDS < END )); do
    kubectl get pods -n "$NS" -l "$SEL" -o wide \
        >> "$RUN/pods-timeline.txt" 2>&1 || true

    STATE="$(probe_state)" ||
        fail "Verifier unavailable during observation"

    [[ "$STATE" != UNKNOWN ]] ||
        fail "Verifier became UNKNOWN"

    if grep -q '\[FENCING VERIFIED\]' "$RUN/controller.log"; then
        echo VERIFIED > "$RUN/fencing-outcome.txt"
    fi

    if grep -q '\[RECOVERY VERIFIED\]' "$RUN/controller.log"; then
        echo VERIFIED > "$RUN/recovery-outcome.txt"
        log "Recovery verified"
        break
    fi

    if grep -q 'RecoveryBlockedFencingFailed' \
        "$RUN/controller.log"; then
        echo BLOCKED > "$RUN/recovery-outcome.txt"
        break
    fi

    sleep 5
done

log "Clearing network fault; preserving storage fence"

remote clear > "$RUN/fault-clear.log" 2>&1 ||
    fail "Network fault cleanup failed"

grep -qx INACTIVE "$RUN/fault-clear.log" ||
    fail "Network fault clearance not verified"

FAULT_CLEARED=true

[[ -f "$RUN/fencing-outcome.txt" ]] ||
    echo NOT_VERIFIED > "$RUN/fencing-outcome.txt"

[[ -f "$RUN/recovery-outcome.txt" ]] ||
    echo NOT_VERIFIED > "$RUN/recovery-outcome.txt"

echo NOT_ATTEMPTED > "$RUN/reconciliation-outcome.txt"

log "Pilot observation completed"
log "Storage fence intentionally retained"