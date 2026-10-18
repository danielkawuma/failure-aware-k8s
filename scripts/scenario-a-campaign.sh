#!/usr/bin/env bash
# Scenario A campaign runner.
#
# Target:
#   5 COMPLETE Native runs
#   5 COMPLETE Failure-Aware runs
#
# Counts existing COMPLETE runs.
# Preserves INCOMPLETE runs.
# Allocates new run IDs automatically.
# Interleaves Native and FA1 where possible.
#
# Worker1 is shut down through SSH by scenario-a-run.sh.
# The operator restarts Worker1 manually through Horizon.
#
# A failed run stops the campaign.
# No automatic retry of an incomplete fault run.
#
# Existing Scenario B/C/D/E scripts are not modified.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE="$ROOT/experiments/evaluation/scenario-a"

TARGET="${SCENARIO_A_TARGET_PER_MODE:-5}"
HOLD="${SCENARIO_A_HOLD_SECONDS:-480}"
PAUSE="${SCENARIO_A_BETWEEN_RUN_SECONDS:-20}"

[[ "$TARGET" =~ ^[0-9]+$ ]] || {
    echo "Invalid target: $TARGET"
    exit 2
}

[[ "$HOLD" =~ ^[0-9]+$ ]] || {
    echo "Invalid hold: $HOLD"
    exit 2
}

[[ "$PAUSE" =~ ^[0-9]+$ ]] || {
    echo "Invalid pause: $PAUSE"
    exit 2
}

(( TARGET > 0 )) || exit 2
(( HOLD >= 300 )) || exit 2

mkdir -p \
    "$BASE/native" \
    "$BASE/failure-aware"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN="$BASE/campaign-$STAMP"

mkdir -p "$CAMPAIGN"

SUMMARY="$CAMPAIGN/summary.csv"
PLAN="$CAMPAIGN/plan.csv"
LOG="$CAMPAIGN/campaign.log"

exec > >(tee -a "$LOG") 2>&1

echo "arm,run,status,reason" > "$SUMMARY"
echo "order,arm,run" > "$PLAN"

utc() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

log() {
    printf '[SCENARIO-A-CAMPAIGN] %s %s\n' "$(utc)" "$*"
}

fail() {
    log "BLOCKED: $*"
    exit 1
}

count_complete() {
    local mode="$1"
    local count=0
    local dir

    for dir in "$BASE/$mode"/run-*; do
        [[ -d "$dir" ]] || continue

        if [[ -f "$dir/COMPLETE" ]]; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

next_run_id() {
    local mode="$1"
    local n=1
    local run

    while true; do
        run="$(printf '%03d' "$n")"

        if [[ ! -e "$BASE/$mode/run-$run" ]]; then
            echo "$run"
            return 0
        fi

        n=$((n + 1))
    done
}

node_ready() {
    local node="$1"

    [[ "$(
        kubectl --request-timeout=8s get node "$node" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
          2>/dev/null
    )" == "True" ]]
}

http_ok() {
    curl -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        "$1" >/dev/null 2>&1
}

preflight() {
    log "Checking cluster before next experiment"

    node_ready k3s-worker1 ||
        fail "Worker1 is not Ready"

    node_ready k3s-worker2 ||
        fail "Worker2 is not Ready"

    local pods

    pods="$(
        kubectl --request-timeout=10s \
          -n failure-aware \
          get pods -l app=baseline-web \
          -o json
    )" || fail "Cannot inspect Nginx Pods"

    python3 -c '
import json
import sys

pods = json.load(sys.stdin)["items"]

assert len(pods) == 1, "Expected exactly one Nginx Pod"

pod = pods[0]

assert pod["spec"].get("nodeName") == "k3s-worker1"
assert pod["status"].get("phase") == "Running"
assert not pod["metadata"].get("deletionTimestamp")

assert any(
    c.get("type") == "Ready"
    and c.get("status") == "True"
    for c in pod["status"].get("conditions", [])
)
' <<< "$pods" || fail "Initial Nginx placement is not clean"

    local selector

    selector="$(
        kubectl -n failure-aware get deployment baseline-web \
          -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}'
    )"

    [[ -z "$selector" ]] ||
        fail "Hard nodeSelector remains: $selector"

    http_ok "http://102.34.160.103:30364/" ||
        fail "Kubernetes Nginx HTTP unavailable"

    http_ok "http://102.34.160.87:8081/" ||
        fail "Standalone Nginx HTTP unavailable"

    log "Preflight passed"
}

record_existing() {
    local mode="$1"
    local dir
    local run

    for dir in "$BASE/$mode"/run-*; do
        [[ -d "$dir" ]] || continue

        run="${dir##*/}"
        run="${run#run-}"

        if [[ -f "$dir/COMPLETE" ]]; then
            echo "$mode,$run,EXISTING_COMPLETE," >> "$SUMMARY"
        else
            echo "$mode,$run,EXISTING_INCOMPLETE,Historical attempt preserved" \
              >> "$SUMMARY"
        fi
    done
}

log "Starting Scenario A campaign"
log "Target per mode: $TARGET"
log "Hold duration: $HOLD seconds"

record_existing native
record_existing failure-aware

NATIVE_COMPLETE="$(count_complete native)"
FA_COMPLETE="$(count_complete failure-aware)"

log "Existing Native COMPLETE: $NATIVE_COMPLETE"
log "Existing FA1 COMPLETE: $FA_COMPLETE"

if (( NATIVE_COMPLETE >= TARGET && FA_COMPLETE >= TARGET )); then
    log "Target already achieved"
    exit 0
fi

# Build a deterministic interleaved plan.
# Prefer the arm with fewer completed runs.
# On equal counts, alternate by selecting FA1 first.

native_count="$NATIVE_COMPLETE"
fa_count="$FA_COMPLETE"
order=0

while (( native_count < TARGET || fa_count < TARGET )); do

    if (( fa_count < TARGET )) &&
       (( native_count >= TARGET || fa_count <= native_count )); then
        mode="failure-aware"
        fa_count=$((fa_count + 1))
    else
        mode="native"
        native_count=$((native_count + 1))
    fi

    order=$((order + 1))

    run="$(next_run_id "$mode")"

    # Reserve this ID within the planning process.
    # No actual run directory is created here.
    #
    # Avoid duplicate allocations by advancing the
    # in-memory next-ID counter for each mode.

    if [[ "$mode" == native ]]; then
        : "${NATIVE_NEXT:=4}"
        while [[ -e "$BASE/native/run-$(printf '%03d' "$NATIVE_NEXT")" ]]; do
            NATIVE_NEXT=$((NATIVE_NEXT + 1))
        done
        run="$(printf '%03d' "$NATIVE_NEXT")"
        NATIVE_NEXT=$((NATIVE_NEXT + 1))
    else
        : "${FA_NEXT:=3}"
        while [[ -e "$BASE/failure-aware/run-$(printf '%03d' "$FA_NEXT")" ]]; do
            FA_NEXT=$((FA_NEXT + 1))
        done
        run="$(printf '%03d' "$FA_NEXT")"
        FA_NEXT=$((FA_NEXT + 1))
    fi

    echo "$order,$mode,$run" >> "$PLAN"
done

log "Campaign plan:"
cat "$PLAN"

# Execute one run at a time.

tail -n +2 "$PLAN" |
while IFS=, read -r order mode run; do

    dir="$BASE/$mode/run-$run"

    log "========================================"
    log "Starting $mode run-$run"
    log "========================================"

    if [[ -e "$dir" ]]; then
        fail "Planned run directory already exists: $dir"
    fi

    preflight

    if SCENARIO_A_HOLD_SECONDS="$HOLD" \
       "$ROOT/scripts/scenario-a-run.sh" "$mode" "$run"; then

        if [[ -f "$dir/COMPLETE" ]]; then
            echo "$mode,$run,COMPLETE," >> "$SUMMARY"
            log "$mode run-$run COMPLETE"
        else
            echo "$mode,$run,INCOMPLETE,Missing COMPLETE marker" \
              >> "$SUMMARY"

            fail "$mode run-$run missing COMPLETE marker"
        fi

    else
        reason="Run execution failed"

        if [[ -f "$dir/failure-reason.txt" ]]; then
            reason="$(
                tr '\n,' '  ' < "$dir/failure-reason.txt"
            )"
        fi

        echo "$mode,$run,INCOMPLETE,$reason" >> "$SUMMARY"

        fail "Campaign stopped at $mode run-$run: $reason"
    fi

    log "Waiting $PAUSE seconds before next experiment"
    sleep "$PAUSE"
done

log "========================================"
log "SCENARIO_A_CAMPAIGN_FINISHED"
log "========================================"

log "Final Native COMPLETE: $(count_complete native)"
log "Final FA1 COMPLETE: $(count_complete failure-aware)"
log "Summary: $SUMMARY"