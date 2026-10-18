#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ==========================================================
# OpenMRS benchmark campaign orchestrator
# ==========================================================

SCENARIOS="${SCENARIOS:-scenario-b,scenario-c,scenario-e}"
MODES="${MODES:-V0,T5,T10,T30,FA1}"

RUNS_PER_MODE="${RUNS_PER_MODE:-10}"
START_RUN="${START_RUN:-1}"

RESET_SECONDS="${RESET_SECONDS:-60}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-2400}"

BASELINE_SECONDS="${BASELINE_SECONDS:-30}"
FAULT_SECONDS="${FAULT_SECONDS:-600}"
POST_FAULT_SECONDS="${POST_FAULT_SECONDS:-30}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-1200}"

ENABLE_FAULTS="${OPENMRS_ENABLE_FAULTS:-false}"
ENABLE_CD="${OPENMRS_ENABLE_CD:-false}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

B_RUNNER="$ROOT/scripts/run-openmrs-experiment.sh"
C_RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
E_RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
CD_RUNNER="$ROOT/scripts/run-openmrs-cd-live-pilot.sh"

RESULT_ROOT="$ROOT/experiments/evaluation/openmrs"
CAMPAIGN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="$RESULT_ROOT/campaigns/$CAMPAIGN_ID"

mkdir -p "$CAMPAIGN_DIR"

LOG="$CAMPAIGN_DIR/campaign.log"
SUMMARY="$CAMPAIGN_DIR/summary.csv"
PLAN="$CAMPAIGN_DIR/plan.csv"

exec > >(tee -a "$LOG") 2>&1

printf 'scenario,mode,profile,run,status,start_utc,end_utc,exit_code\n' \
    > "$SUMMARY"

printf 'scenario,mode,profile,run\n' > "$PLAN"

export SSH_KEY
export OPENMRS_ENABLE_FAULTS="$ENABLE_FAULTS"
export BASELINE_SECONDS
export FAULT_SECONDS
export POST_FAULT_SECONDS
export RECOVERY_TIMEOUT_SECONDS

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

valid_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

# ==========================================================
# Configuration validation
# ==========================================================

valid_integer "$RUNS_PER_MODE" ||
    fail "Invalid RUNS_PER_MODE"

valid_integer "$START_RUN" ||
    fail "Invalid START_RUN"

valid_integer "$RUN_TIMEOUT_SECONDS" ||
    fail "Invalid RUN_TIMEOUT_SECONDS"

[[ -f "$SSH_KEY" ]] ||
    fail "SSH private key missing"

command -v kubectl >/dev/null ||
    fail "kubectl unavailable"

command -v timeout >/dev/null ||
    fail "timeout unavailable"

command -v shuf >/dev/null ||
    fail "shuf unavailable"

IFS=',' read -r -a SCENARIO_LIST <<< "$SCENARIOS"
IFS=',' read -r -a MODE_LIST <<< "$MODES"

# ==========================================================
# Cluster health
# ==========================================================

deployment_ready() {
    local namespace="$1"
    local deployment="$2"

    kubectl --request-timeout=10s \
        get deployment "$deployment" \
        -n "$namespace" -o json |
        python3 -c '
import json,sys
d=json.load(sys.stdin)
desired=d["spec"].get("replicas",1)
status=d.get("status",{})
ok=(
    desired==1
    and status.get("readyReplicas",0)==1
    and status.get("availableReplicas",0)==1
    and status.get("observedGeneration",0)
        >= d["metadata"].get("generation",0)
)
sys.exit(0 if ok else 1)
'
}

clinical_healthy() {
    curl -fsS \
        --connect-timeout 3 \
        --max-time 10 \
        "${OPENMRS_HEALTH_URL:-http://102.34.160.87:30366/openmrs/health/started}" \
        >/dev/null
}

cluster_healthy() {
    deployment_ready openmrs37 openmrs-backend &&
    deployment_ready openmrs37 openmrs-mariadb &&
    clinical_healthy
}

wait_healthy() {
    local deadline=$((SECONDS + 900))

    while (( SECONDS < deadline )); do
        if cluster_healthy; then
            return 0
        fi
        sleep 10
    done

    return 1
}

# ==========================================================
# NFS fence verification
# ==========================================================

# This check deliberately fails closed.
# UNKNOWN and SSH transport errors are not NOT_FENCED.

fence_inactive() {
    local node="$1"
    local ip output rc

    ip="$(
        kubectl get node "$node" \
          -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
    )" || return 1

    [[ -n "$ip" ]] || return 1

    output="$(
        FAILURE_AWARE_FENCE_MODE=nfs \
        FAILURE_AWARE_FENCE_WORKER_IP="$ip" \
        FAILURE_AWARE_FENCE_WORKLOAD_NODE="$node" \
        FAILURE_AWARE_SSH_COMMAND_TIMEOUT=8 \
        "$ROOT/scripts/storage-fence.sh" status 2>&1
    )" && rc=0 || rc=$?

    [[ "$rc" -eq 1 ]] &&
    grep -qx 'NOT_FENCED' <<< "$output" &&
    ! grep -Eqi 'timeout|unknown|unverified|transport' <<< "$output"
}

check_all_fences() {
    local node

    for node in k3s-worker1 k3s-worker2 k3s-worker3 k3s-worker4; do
        fence_inactive "$node" ||
            fail "NFS fence is active or unknown on $node"
    done
}

# ==========================================================
# Workload starting placement
# ==========================================================

backend_on_fault_target() {
    local expected="${OPENMRS_BACKEND_FAULT_NODE:-k3s-worker1}"

    kubectl get pods -n openmrs37 \
        -l app=openmrs-backend -o json |
        python3 -c '
import json,sys
pods=json.load(sys.stdin)["items"]
ready=[
 p for p in pods
 if p["spec"].get("nodeName")==sys.argv[1]
 and not p["metadata"].get("deletionTimestamp")
 and any(c.get("type")=="Ready" and c.get("status")=="True"
         for c in p.get("status",{}).get("conditions",[]))
]
sys.exit(0 if len(ready)==1 else 1)
' "$expected"
}

# ==========================================================
# Execute one scenario
# ==========================================================

run_one() {
    local scenario="$1"
    local mode="$2"
    local profile="$3"
    local run_id="$4"

    local start end rc status

    start="$(timestamp)"

    log "=============================================="
    log "Scenario=$scenario Mode=$mode Profile=$profile"
    log "Run=$run_id"
    log "=============================================="

    wait_healthy ||
        fail "OpenMRS unhealthy before experiment"

    check_all_fences

    if [[ "$scenario" != scenario-c-d ]]; then
        backend_on_fault_target ||
            fail "Backend is not Ready on the configured fault node"
    fi

    rc=0

    case "$scenario" in

        scenario-b)
            timeout --signal=TERM --kill-after=30s \
                "$RUN_TIMEOUT_SECONDS" \
                "$B_RUNNER" scenario-b "$mode" "$run_id" ||
                rc=$?
            ;;

        scenario-c)
            timeout --signal=TERM --kill-after=30s \
                "$RUN_TIMEOUT_SECONDS" \
                "$C_RUNNER" scenario-c "$mode" "$run_id" ||
                rc=$?
            ;;

        scenario-e)
            timeout --signal=TERM --kill-after=30s \
                "$RUN_TIMEOUT_SECONDS" \
                "$E_RUNNER" scenario-e "$mode" "$run_id" "$profile" ||
                rc=$?
            ;;

        scenario-c-d)
            [[ "$mode" == FA1 ]] ||
                fail "C+D currently supports only FA1"

            [[ "$ENABLE_CD" == true ]] ||
                fail "C+D requires OPENMRS_ENABLE_CD=true"

            [[ "${OPENMRS_CD_ACK_COLLATERAL_IMPACT:-false}" == true &&
               "${OPENMRS_CD_ACK_LIVE_WRITER_RISK:-false}" == true ]] ||
                fail "C+D live test acknowledgments missing"

            timeout --signal=TERM --kill-after=30s \
                "$RUN_TIMEOUT_SECONDS" \
                "$CD_RUNNER" ||
                rc=$?
            ;;

        *)
            fail "Unknown scenario: $scenario"
            ;;
    esac

    end="$(timestamp)"

    if (( rc != 0 )); then
        status="FAILED"
    else
        status="OBSERVATION_COMPLETE"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$scenario" "$mode" "$profile" "$run_id" \
        "$status" "$start" "$end" "$rc" \
        >> "$SUMMARY"

    (( rc == 0 )) ||
        fail "Experiment failed: $scenario/$mode/$run_id"

    # Runner exit 0 is not proof of successful recovery.
    # Require restored service and cleared fencing state.
    wait_healthy ||
        fail "OpenMRS did not return to a healthy state"

    check_all_fences

    log "Observation completed: $scenario/$mode/$run_id"
    log "Waiting ${RESET_SECONDS}s before next run"

    sleep "$RESET_SECONDS"
}

# ==========================================================
# Campaign plan
# ==========================================================

log "Campaign ID: $CAMPAIGN_ID"
log "Scenarios: $SCENARIOS"
log "Modes: $MODES"
log "Runs per mode: $RUNS_PER_MODE"

for scenario in "${SCENARIO_LIST[@]}"; do

    case "$scenario" in
        scenario-b|scenario-c|scenario-e|scenario-c-d) ;;
        *) fail "Unsupported scenario: $scenario" ;;
    esac

    for (( round=0; round<RUNS_PER_MODE; round++ )); do

        run_id="$(printf '%03d' "$((10#$START_RUN + round))")"

        if [[ "$scenario" == scenario-c-d ]]; then
            printf '%s,%s,%s,%s\n' \
                "$scenario" FA1 none "$run_id" >> "$PLAN"
            continue
        fi

        mapfile -t ordered_modes < <(
            printf '%s\n' "${MODE_LIST[@]}" | shuf
        )

        for mode in "${ordered_modes[@]}"; do
            case "$mode" in
                V0|T5|T10|T30|FA1) ;;
                *) fail "Unsupported mode: $mode" ;;
            esac

            if [[ "$scenario" == scenario-e ]]; then
                for profile in mild moderate severe; do
                    printf '%s,%s,%s,%s\n' \
                        "$scenario" "$mode" "$profile" "$run_id" \
                        >> "$PLAN"
                done
            else
                printf '%s,%s,%s,%s\n' \
                    "$scenario" "$mode" none "$run_id" \
                    >> "$PLAN"
            fi
        done
    done
done

log "Campaign plan saved: $PLAN"

# ==========================================================
# Explicit execution gate
# ==========================================================

if [[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" != true ]]; then
    log "PLAN ONLY — no experiments executed"
    log "Set OPENMRS_CAMPAIGN_EXECUTE=true to execute"
    exit 0
fi

[[ "$ENABLE_FAULTS" == true ]] ||
    fail "OPENMRS_ENABLE_FAULTS=true is required"

# ==========================================================
# Execute campaign
# ==========================================================

while IFS=',' read -r scenario mode profile run_id; do

    [[ "$scenario" == scenario ]] && continue

    # Existing experiment directories are never overwritten.
    if [[ "$scenario" != scenario-c-d ]]; then

        dir="$RESULT_ROOT/$scenario/$mode/run-$run_id"

        [[ ! -e "$dir" ]] ||
            fail "Existing run directory: $dir"
    fi

    run_one "$scenario" "$mode" "$profile" "$run_id"

done < "$PLAN"

log "CAMPAIGN OBSERVATIONS COMPLETE"
log "Results: $CAMPAIGN_DIR"