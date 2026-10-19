#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

RUNNER="$ROOT/scripts/openmrs/backend/run-openmrs-experiment.sh"
FAULT="$ROOT/scripts/fault.sh"

SCENARIO="scenario-b"
NAMESPACE="openmrs37"
DEPLOYMENT="openmrs-backend"

RUNS_PER_MODE="${RUNS_PER_MODE:-10}"
START_RUN="${START_RUN:-2}"
RESET_SECONDS="${RESET_SECONDS:-45}"

CAMPAIGN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN_DIR="$ROOT/experiments/evaluation/openmrs/campaign-$CAMPAIGN_ID"

mkdir -p "$CAMPAIGN_DIR"

LOG="$CAMPAIGN_DIR/campaign.log"
SUMMARY="$CAMPAIGN_DIR/summary.csv"

exec > >(tee -a "$LOG") 2>&1

echo "mode,run,status,start_utc,end_utc" > "$SUMMARY"

export SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
export OPENMRS_ENABLE_FAULTS=true
export BASELINE_SECONDS="${BASELINE_SECONDS:-30}"
export FAULT_SECONDS="${FAULT_SECONDS:-360}"
export POST_FAULT_SECONDS="${POST_FAULT_SECONDS:-30}"

# Failure-Aware mode requires its own successful pilot.
ENABLE_FA1="${ENABLE_FA1:-false}"

MODES=(V0 T5 T10 T30)

if [[ "$ENABLE_FA1" == true ]]; then
    MODES+=(FA1)
fi

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
    echo "[$(timestamp)] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

fault_clear() {
    "$FAULT" scenario-b clear
}

fault_absent() {
    ssh -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        ubuntu@102.34.160.87 \
        'if sudo -n iptables -C OUTPUT \
             -p tcp -d 102.34.160.89 \
             --dport 6443 -j DROP 2>/dev/null; then
             exit 1
         fi'
}

healthy() {
    local ready available

    ready="$(
        kubectl get node k3s-worker1 \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
    )"

    [[ "$ready" == True ]] || return 1

    available="$(
        kubectl get deployment "$DEPLOYMENT" \
            -n "$NAMESPACE" \
            -o jsonpath='{.status.availableReplicas}'
    )"

    [[ "$available" == 1 ]] || return 1

    curl --silent --show-error --fail \
        --connect-timeout 3 \
        --max-time 10 \
        http://102.34.160.87:30366/openmrs/health/started \
        >/dev/null
}

wait_healthy() {
    local deadline=$((SECONDS + 180))

    while (( SECONDS < deadline )); do
        if healthy; then
            return 0
        fi
        sleep 5
    done

    return 1
}

verify_run() {
    local dir="$1"

    [[ -f "$dir/COMPLETE" ]] || return 1
    [[ ! -f "$dir/INCOMPLETE" ]] || return 1
    [[ -f "$dir/experiment-metadata.json" ]] || return 1
    [[ -f "$dir/fault-apply.log" ]] || return 1
    [[ -f "$dir/fault-clear.log" ]] || return 1
    [[ -f "$dir/harness.log" ]] || return 1

    # This is an operational completion check,
    # not statistical or clinical correctness validation.
}

on_exit() {
    local rc=$?

    trap - EXIT INT TERM

    if ! fault_absent; then
        log "WARNING: fault state cannot be confirmed clear."
        log "Manual intervention may be required."
    fi

    log "Campaign exiting with status $rc"
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Starting OpenMRS overnight campaign"
log "Campaign: $CAMPAIGN_ID"

[[ "$RUNS_PER_MODE" =~ ^[0-9]+$ ]] ||
    fail "Invalid run count"

(( RUNS_PER_MODE > 0 )) ||
    fail "Run count must be positive"

[[ "$START_RUN" =~ ^[0-9]+$ ]] ||
    fail "Invalid starting run"

[[ -x "$RUNNER" ]] ||
    fail "Experiment runner not executable"

[[ -f "$SSH_KEY" ]] ||
    fail "SSH key missing"

# Avoid starting with a stale partition.
fault_absent ||
    fail "Existing fault or SSH failure detected"

wait_healthy ||
    fail "OpenMRS not healthy at campaign start"

# Randomize mode order independently for each round.
for (( round=0; round<RUNS_PER_MODE; round++ )); do

    run_number=$((START_RUN + round))
    run_id="$(printf '%03d' "$run_number")"

    mapfile -t ordered_modes < <(
        printf '%s\n' "${MODES[@]}" | shuf
    )

    for mode in "${ordered_modes[@]}"; do

        dir="$ROOT/experiments/evaluation/openmrs/$SCENARIO/$mode/run-$run_id"

        [[ ! -e "$dir" ]] ||
            fail "Run directory already exists: $dir"

        log "======================================"
        log "Starting $SCENARIO / $mode / $run_id"
        log "======================================"

        fault_absent ||
            fail "Fault state unsafe before run"

        wait_healthy ||
            fail "OpenMRS failed pre-run health check"

        start="$(timestamp)"

        if timeout --signal=TERM \
            --kill-after=30s \
            900s \
            "$RUNNER" "$SCENARIO" "$mode" "$run_id"
        then
            runner_rc=0
        else
            runner_rc=$?
        fi

        end="$(timestamp)"

        if (( runner_rc != 0 )); then
            echo "$mode,$run_id,FAILED,$start,$end" >> "$SUMMARY"
            fail "Experiment runner failed: $mode/$run_id"
        fi

        if ! verify_run "$dir"; then
            echo "$mode,$run_id,INVALID,$start,$end" >> "$SUMMARY"
            fail "Missing experiment evidence"
        fi

        if ! fault_absent; then
            echo "$mode,$run_id,FAULT_ACTIVE,$start,$end" >> "$SUMMARY"
            fail "Fault not confirmed cleared"
        fi

        if ! wait_healthy; then
            echo "$mode,$run_id,UNHEALTHY,$start,$end" >> "$SUMMARY"
            fail "OpenMRS did not recover"
        fi

        echo "$mode,$run_id,COMPLETE,$start,$end" >> "$SUMMARY"

        log "Completed $mode/$run_id"
        log "Reset wait: ${RESET_SECONDS}s"

        sleep "$RESET_SECONDS"
    done
done

log "All scheduled experiments completed."
log "Results: $CAMPAIGN_DIR"