#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

NAMESPACE="${OPENMRS_CD_NAMESPACE:-openmrs37}"
DEPLOYMENT="${OPENMRS_CD_DEPLOYMENT:-openmrs-mariadb}"
SELECTOR="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"

DB_PORT="${OPENMRS_DB_PORT:-3306}"
PROBE_PORT="${OPENMRS_DB_PROBE_HTTP_PORT:-18086}"

OBSERVE_SECONDS="${OPENMRS_CD_OBSERVE_SECONDS:-900}"
RECOVERY_TIMEOUT_MS="${FAILURE_AWARE_RECOVERY_TIMEOUT_MS:-1200000}"
FENCING_TIMEOUT_MS="${FAILURE_AWARE_FENCING_TIMEOUT_MS:-120000}"

REMOTE_FAULT_SCRIPT="${OPENMRS_CD_REMOTE_FAULT_SCRIPT:-/usr/local/sbin/openmrs-cd-fault}"

CONFIG_DIR="$ROOT/experiments/evaluation/openmrs/scenario-c-d"
RUN="$CONFIG_DIR/pilot-$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$RUN"

exec > >(tee -a "$RUN/pilot.log") 2>&1

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)] $*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

timestamp() {
    date -u +%Y-%m-%dT%H:%M:%S.%NZ
}

record() {
    timestamp > "$RUN/$1"
}

CONTROLLER_PID=""
PROBE_PID=""

FAULT_ATTEMPTED=false
FAULT_CLEARED=false

ORIGINAL=""
IP=""
CANDIDATE=""
POD_IP=""

REMOTE_HOST=""

FENCE_SCRIPT="$ROOT/scripts/openmrs-cd-fence-original.sh"
PROBE_SCRIPT="$ROOT/scripts/openmrs-db-probe.py"
PREPARE_SCRIPT="$ROOT/scripts/openmrs-cd-prepare.py"
CONTROLLER="$ROOT/controller/target/debug/failure-aware-controller"

# --------------------------------------------------
# Acknowledgments
# --------------------------------------------------

: "${OPENMRS_CD_ACK_COLLATERAL_IMPACT:=false}"
: "${OPENMRS_CD_ACK_LIVE_WRITER_RISK:=false}"

if [[ "$OPENMRS_CD_ACK_COLLATERAL_IMPACT" != true ||
      "$OPENMRS_CD_ACK_LIVE_WRITER_RISK" != true ]]; then

    fail "Live test disabled: both acknowledgments are required"
fi

# --------------------------------------------------
# Dependency validation
# --------------------------------------------------

[[ -x "$CONTROLLER" ]] ||
    fail "Controller binary missing"

[[ -f "$PREPARE_SCRIPT" ]] ||
    fail "Database preparation script missing"

[[ -f "$PROBE_SCRIPT" ]] ||
    fail "Database TCP probe missing"

[[ -x "$FENCE_SCRIPT" ]] ||
    fail "Database fencing script missing"

[[ -f "$SSH_KEY" ]] ||
    fail "SSH private key missing"

command -v kubectl >/dev/null ||
    fail "kubectl unavailable"

command -v python3 >/dev/null ||
    fail "python3 unavailable"

command -v curl >/dev/null ||
    fail "curl unavailable"

# --------------------------------------------------
# Dynamic original-writer discovery
# --------------------------------------------------

log "Discovering original MariaDB authority"

python3 "$PREPARE_SCRIPT" "$RUN/controller.json"

read -r ORIGINAL IP CANDIDATE POD_IP < <(
    python3 - "$RUN/controller-authority.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

print(
    data["node"],
    data["ip"],
    data["candidate"],
    data["pod_ip"]
)
PY
)

[[ -n "$ORIGINAL" ]] ||
    fail "Original worker not identified"

[[ -n "$IP" ]] ||
    fail "Original worker IP missing"

[[ -n "$CANDIDATE" ]] ||
    fail "Recovery candidate missing"

[[ -n "$POD_IP" ]] ||
    fail "Original MariaDB Pod IP missing"

[[ "$ORIGINAL" != "$CANDIDATE" ]] ||
    fail "Recovery candidate equals original worker"

[[ "$POD_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Invalid original MariaDB Pod IP"

REMOTE_HOST="ubuntu@$IP"

log "Original worker: $ORIGINAL"
log "Original IP: $IP"
log "Original database Pod IP: $POD_IP"
log "Recovery candidate: $CANDIDATE"

# --------------------------------------------------
# Preserve original authority for fencing
# --------------------------------------------------

export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL"
export OPENMRS_CD_ORIGINAL_IP="$IP"

export FAILURE_AWARE_FENCE_WORKER_IP="$IP"
export FAILURE_AWARE_FENCE_WORKLOAD_NODE="$ORIGINAL"
export FAILURE_AWARE_FENCE_WORKLOAD_ID="$NAMESPACE/$DEPLOYMENT"

# --------------------------------------------------
# Remote fault orchestration
# --------------------------------------------------

remote() {
    local action="$1"

    timeout 20 ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "$REMOTE_HOST" \
        "sudo -n $REMOTE_FAULT_SCRIPT $action $POD_IP"
}

# --------------------------------------------------
# Fence status classification
# --------------------------------------------------

# Returns:
#   0 = FENCED
#   1 = NOT_FENCED
#   2 = UNKNOWN
#
# The wrapper's exit code alone is insufficient.
# Both output and exit status must agree.

fence_state() {
    local output_file="$1"
    local rc

    set +e

    "$FENCE_SCRIPT" status \
        > "$output_file" 2>&1

    rc=$?

    set -e

    if [[ "$rc" -eq 0 ]] &&
       grep -qx 'FENCED' "$output_file"; then

        return 0
    fi

    if [[ "$rc" -eq 1 ]] &&
       grep -qx 'NOT_FENCED' "$output_file" &&
       ! grep -Eqi \
         'timeout|timed out|unknown|unverified|transport failure' \
         "$output_file"; then

        return 1
    fi

    return 2
}

verify_initial_fence() {
    local rc

    log "Checking initial NFS fence state"

    fence_state "$RUN/initial-fence.log" && rc=0 || rc=$?

    case "$rc" in
        0)
            fail "NFS fence already active"
            ;;

        1)
            log "NFS fence confirmed inactive"
            ;;

        *)
            cat "$RUN/initial-fence.log" >&2
            fail "NFS fence state UNKNOWN; refusing fault injection"
            ;;
    esac
}

# --------------------------------------------------
# Cleanup
# --------------------------------------------------

cleanup() {
    local rc=$?

    trap - EXIT INT TERM
    set +e

    log "Starting pilot cleanup"

    if [[ "$FAULT_ATTEMPTED" == true &&
          "$FAULT_CLEARED" != true ]]; then

        log "Attempting network fault cleanup"

        if remote clear \
            > "$RUN/emergency-fault-clear.log" 2>&1; then

            FAULT_CLEARED=true
            log "Network fault cleared"
        else
            log "WARNING: Network fault cleanup could not be verified"
        fi
    fi

    if [[ -n "$CONTROLLER_PID" ]]; then
        kill "$CONTROLLER_PID" 2>/dev/null
        wait "$CONTROLLER_PID" 2>/dev/null
    fi

    if [[ -n "$PROBE_PID" ]]; then
        kill "$PROBE_PID" 2>/dev/null
        wait "$PROBE_PID" 2>/dev/null
    fi

    kubectl get pods \
        -n "$NAMESPACE" \
        -o wide \
        > "$RUN/final-pods.txt" 2>&1

    kubectl get nodes \
        -o wide \
        > "$RUN/final-nodes.txt" 2>&1

    if [[ -n "$ORIGINAL" && -n "$IP" ]]; then
        "$FENCE_SCRIPT" status \
            > "$RUN/final-fence.log" 2>&1
    fi

    # Never automatically remove a live-writer NFS fence.
    log "NFS fence retained if active"
    log "Old-writer reconciliation required before unfencing"

    if [[ "$rc" -eq 0 &&
          "$FAULT_CLEARED" == true ]]; then

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

# --------------------------------------------------
# Verify flexible database placement
# --------------------------------------------------

log "Checking database placement configuration"

SELECTOR_NODE="$(
    kubectl get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}'
)"

[[ -z "$SELECTOR_NODE" ]] ||
    fail "MariaDB is pinned to $SELECTOR_NODE"

# --------------------------------------------------
# Initial NFS fence verification
# --------------------------------------------------

verify_initial_fence

# --------------------------------------------------
# Verify management SSH
# --------------------------------------------------

log "Checking original worker SSH access"

timeout 15 ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$REMOTE_HOST" \
    'echo SSH_OK' \
    > "$RUN/worker-ssh.log" 2>&1 ||
    fail "Original worker SSH unavailable"

# --------------------------------------------------
# Verify remote fault script
# --------------------------------------------------

log "Checking remote fault mechanism"

timeout 15 ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$REMOTE_HOST" \
    "sudo -n test -x $REMOTE_FAULT_SCRIPT" ||
    fail "Remote fault script unavailable"

if remote status \
    > "$RUN/initial-fault.log" 2>&1; then

    fail "A network fault is already active"
fi

# --------------------------------------------------
# Start independent MariaDB TCP probe
# --------------------------------------------------

log "Starting independent MariaDB TCP probe"

python3 "$PROBE_SCRIPT" \
    --host "$POD_IP" \
    --port "$DB_PORT" \
    --http-port "$PROBE_PORT" \
    > "$RUN/db-probe.log" 2>&1 &

PROBE_PID=$!

sleep 2

kill -0 "$PROBE_PID" 2>/dev/null ||
    fail "MariaDB TCP probe exited"

curl -fsS \
    --max-time 5 \
    "http://127.0.0.1:$PROBE_PORT/health" \
    > "$RUN/pre-fault-probe.txt" ||
    fail "Original MariaDB is not reachable before fault"

log "Original MariaDB TCP/3306 reachable"

# --------------------------------------------------
# Start Failure-Aware controller
# --------------------------------------------------

log "Starting Failure-Aware controller"

FAILURE_AWARE_RECOVERY_TIMEOUT_MS="$RECOVERY_TIMEOUT_MS" \
FAILURE_AWARE_FENCING_TIMEOUT_MS="$FENCING_TIMEOUT_MS" \
FAILURE_AWARE_CONTROLLER_CONFIG="$RUN/controller.json" \
    "$CONTROLLER" \
    > "$RUN/controller.log" 2>&1 &

CONTROLLER_PID=$!

sleep 10

kill -0 "$CONTROLLER_PID" 2>/dev/null ||
    fail "Controller exited during preflight"

record "controller-started-time.txt"

# --------------------------------------------------
# Inject Scenario C database fault
# --------------------------------------------------

log "Injecting database-worker isolation fault"

FAULT_ATTEMPTED=true

remote apply \
    > "$RUN/fault-apply.log" 2>&1 ||
    fail "Remote fault application failed"

record "fault-time.txt"

log "Fault applied to original worker $ORIGINAL"

# --------------------------------------------------
# Verify database isolation
# --------------------------------------------------

log "Verifying original MariaDB is unreachable"

ISOLATED=false

for attempt in 1 2 3 4 5; do

    if ! curl -fsS \
        --max-time 3 \
        "http://127.0.0.1:$PROBE_PORT/health" \
        > "$RUN/post-fault-probe.txt" 2>&1; then

        ISOLATED=true
        break
    fi

    sleep 2
done

[[ "$ISOLATED" == true ]] ||
    fail "Original MariaDB remains reachable after fault"

record "database-isolated-time.txt"

log "Original MariaDB TCP verification failed as expected"

# --------------------------------------------------
# Observe Scenario C -> D -> F
# --------------------------------------------------

log "Observing controller recovery workflow"

END=$((SECONDS + OBSERVE_SECONDS))

RECOVERY_REPORTED=false
FENCING_FAILED=false

while (( SECONDS < END )); do

    kubectl get pods \
        -n "$NAMESPACE" \
        -l "$SELECTOR" \
        -o wide \
        >> "$RUN/pods-timeline.txt" 2>&1 || true

    if grep -q '\[RECOVERY VERIFIED\]' \
        "$RUN/controller.log"; then

        RECOVERY_REPORTED=true
        record "recovery-reported-time.txt"

        log "Controller reported recovery verified"
        break
    fi

    if grep -q 'RecoveryBlockedFencingFailed' \
        "$RUN/controller.log"; then

        FENCING_FAILED=true
        break
    fi

    if ! kill -0 "$CONTROLLER_PID" 2>/dev/null; then
        fail "Controller exited unexpectedly"
    fi

    sleep 5
done

if [[ "$FENCING_FAILED" == true ]]; then
    fail "Controller blocked recovery because fencing failed"
fi

if [[ "$RECOVERY_REPORTED" != true ]]; then
    log "Recovery was not verified within observation window"
    printf '%s\n' "TIMEOUT" > "$RUN/recovery-outcome.txt"
else
    printf '%s\n' "RECOVERY_REPORTED" \
        > "$RUN/recovery-outcome.txt"
fi

# --------------------------------------------------
# Clear network fault
# --------------------------------------------------

log "Clearing network fault"

remote clear \
    > "$RUN/fault-clear.log" 2>&1 ||
    fail "Network fault cleanup failed"

FAULT_CLEARED=true

record "fault-clear-time.txt"

log "Network fault cleared"

# --------------------------------------------------
# Preserve NFS fence and evidence
# --------------------------------------------------

log "Scenario C+D pilot observation completed"
log "NFS fencing state will be retained for reconciliation"
log "No automatic unfencing will be performed"