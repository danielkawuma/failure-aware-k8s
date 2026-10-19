#!/usr/bin/env bash
# Resumable OpenMRS Scenario C+D campaign.
# One logical run = placement preparation + pilot +
# verified recovery + SSH reconciliation + evidence.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

BASE="$ROOT/experiments/evaluation/openmrs/scenario-c-d"
LOGICAL_ROOT="$BASE/logical-runs"

RUNS="${RUNS_PER_MODE:-1}"
START="${START_RUN:-10}"

RUN_TIMEOUT="${RUN_TIMEOUT_SECONDS:-2400}"
RECONCILE_TIMEOUT="${OPENMRS_CD_RECONCILE_TIMEOUT_SECONDS:-1500}"
RESET_SECONDS="${RESET_SECONDS:-30}"

ORIGINAL="${OPENMRS_CD_ORIGINAL_NODE:-k3s-worker3}"
CANDIDATE="${OPENMRS_CD_CANDIDATE_NODE:-k3s-worker2}"

NS="${OPENMRS_CD_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_CD_DEPLOYMENT:-openmrs-mariadb}"
SEL="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"

PILOT="$ROOT/scripts/run-openmrs-cd-live-pilot.sh"
RESET="$ROOT/scripts/openmrs-cd-reset-placement.sh"
RECONCILE="$ROOT/scripts/openmrs-cd-auto-reconcile.sh"
FENCE="$ROOT/scripts/storage-fence.sh"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

CAMPAIGN="$BASE/campaign-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$CAMPAIGN" "$LOGICAL_ROOT"

exec > >(tee -a "$CAMPAIGN/campaign.log") 2>&1

SUMMARY="$CAMPAIGN/summary.csv"
PLAN="$CAMPAIGN/plan.csv"

printf 'run,status,pilot_dir,details\n' > "$SUMMARY"
printf 'run,action\n' > "$PLAN"

log() {
    printf '[CD] %s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

fail() {
    log "BLOCKED: $*" >&2
    exit 1
}

record() {
    printf '%s,%s,%s,%s\n' \
        "$1" "$2" "$3" "$4" >> "$SUMMARY"
}

for value in \
    "$RUNS" "$START" "$RUN_TIMEOUT" \
    "$RECONCILE_TIMEOUT" "$RESET_SECONDS"; do

    [[ "$value" =~ ^[0-9]+$ ]] ||
        fail "Invalid numeric configuration"
done

(( RUNS > 0 && START > 0 )) ||
    fail "Invalid run range"

[[ "${OPENMRS_ENABLE_CD:-false}" == true ]] ||
    fail "OPENMRS_ENABLE_CD=true required"

[[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" == true ]] ||
    fail "OPENMRS_CAMPAIGN_EXECUTE=true required"

[[ "${OPENMRS_CD_ACK_COLLATERAL_IMPACT:-false}" == true ]] ||
    fail "Collateral impact acknowledgment required"

[[ "${OPENMRS_CD_ACK_LIVE_WRITER_RISK:-false}" == true ]] ||
    fail "Live writer risk acknowledgment required"

[[ "$ORIGINAL" == k3s-worker3 ]] ||
    fail "Unexpected original worker"

[[ "$CANDIDATE" == k3s-worker2 ]] ||
    fail "Unexpected recovery candidate"

[[ -r "$SSH_KEY" ]] || fail "SSH key unavailable"

for script in "$PILOT" "$RESET" "$RECONCILE" "$FENCE"; do
    [[ -x "$script" ]] ||
        fail "Missing executable: $script"
done

export SSH_KEY
export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL"
export OPENMRS_CD_CANDIDATE_NODE="$CANDIDATE"

export OPENMRS_CD_ALLOW_SSH_REBOOT=true
export OPENMRS_CD_ALLOW_UNFENCE=true

export OPENMRS_CD_REBOOT_WAIT_SECONDS="${OPENMRS_CD_REBOOT_WAIT_SECONDS:-600}"
export OPENMRS_CD_RUNTIME_WAIT_SECONDS="${OPENMRS_CD_RUNTIME_WAIT_SECONDS:-240}"
export OPENMRS_CD_SANDBOX_WAIT_SECONDS="${OPENMRS_CD_SANDBOX_WAIT_SECONDS:-180}"
export OPENMRS_CD_STABILITY_SECONDS="${OPENMRS_CD_STABILITY_SECONDS:-30}"

export FAILURE_AWARE_SSH_COMMAND_TIMEOUT="${FAILURE_AWARE_SSH_COMMAND_TIMEOUT:-30}"

run_directory() {
    printf '%s/run-%03d\n' "$LOGICAL_ROOT" "$1"
}

run_status() {
    local dir="$1"

    if [[ ! -e "$dir" ]]; then
        echo MISSING
        return
    fi

    if [[ -f "$dir/COMPLETE" &&
          ! -e "$dir/INCOMPLETE" &&
          -s "$dir/pilot-directory.txt" &&
          -s "$dir/reconciliation.log" ]]; then

        local pilot_dir
        pilot_dir="$(cat "$dir/pilot-directory.txt")"

        if [[ -f "$pilot_dir/controller.log" ]] &&
           grep -q '\[FENCING VERIFIED\]' \
               "$pilot_dir/controller.log" &&
           grep -q '\[RECOVERY VERIFIED\]' \
               "$pilot_dir/controller.log" &&
           grep -q 'RECONCILIATION_VERIFIED' \
               "$dir/reconciliation.log"; then
            echo COMPLETE
            return
        fi
    fi

    echo INCOMPLETE
}

node_ip() {
    kubectl get node "$1" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

fence_inactive() {
    local node="$1" ip="$2" output rc=0

    output="$(
        FAILURE_AWARE_FENCE_MODE=nfs \
        FAILURE_AWARE_FENCE_WORKER_IP="$ip" \
        FAILURE_AWARE_FENCE_WORKLOAD_NODE="$node" \
        "$FENCE" status 2>&1
    )" || rc=$?

    [[ "$rc" -eq 1 ]] &&
        grep -qx NOT_FENCED <<< "$output"
}

snapshot_pilots() {
    find "$BASE" \
        -maxdepth 1 \
        -type d \
        -name 'pilot-*' \
        -printf '%f\n' | sort
}

verify_start() {
    local dir="$1"

    kubectl get node "$ORIGINAL" -o json |
        python3 -c '
import json,sys
n=json.load(sys.stdin)
assert not n["spec"].get("unschedulable",False)
assert any(
    c["type"]=="Ready" and c["status"]=="True"
    for c in n["status"].get("conditions",[])
)
' || return 1

    kubectl -n "$NS" get pods -l "$SEL" -o json |
        python3 -c '
import json,sys
pods=json.load(sys.stdin)["items"]
assert len(pods)==1
p=pods[0]
assert p["spec"]["nodeName"]==sys.argv[1]
assert p["status"]["phase"]=="Running"
assert not p["metadata"].get("deletionTimestamp")
assert any(
    c["type"]=="Ready" and c["status"]=="True"
    for c in p["status"].get("conditions",[])
)
' "$ORIGINAL" || return 1

    local selector
    selector="$(
        kubectl -n "$NS" get deployment "$DEP" \
            -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}'
    )"

    [[ -z "$selector" ]] || return 1

    local original_ip candidate_ip
    original_ip="$(node_ip "$ORIGINAL")"
    candidate_ip="$(node_ip "$CANDIDATE")"

    fence_inactive "$ORIGINAL" "$original_ip" || return 1
    fence_inactive "$CANDIDATE" "$candidate_ip" || return 1

    curl -fsS \
        --connect-timeout 3 \
        --max-time 10 \
        -o /dev/null \
        "http://102.34.160.104:30366/openmrs/health/started" ||
        return 1

    echo START_VERIFIED > "$dir/start-verification.txt"
}

log "Generating campaign plan"

for ((i=0; i<RUNS; i++)); do
    number=$((START + i))
    id="$(printf '%03d' "$number")"
    dir="$(run_directory "$number")"
    status="$(run_status "$dir")"

    case "$status" in
        COMPLETE)
            printf '%s,SKIP_COMPLETE\n' "$id" >> "$PLAN"
            ;;
        MISSING)
            printf '%s,EXECUTE\n' "$id" >> "$PLAN"
            ;;
        INCOMPLETE)
            printf '%s,BLOCKED_INCOMPLETE\n' "$id" >> "$PLAN"
            ;;
    esac
done

cat "$PLAN"

mapfile -t PLAN_ROWS < "$PLAN"

for row in "${PLAN_ROWS[@]}"; do
    IFS=',' read -r id action <<< "$row"

    [[ "$id" == run ]] && continue

    number=$((10#$id))
    dir="$(run_directory "$number")"

    case "$action" in
        SKIP_COMPLETE)
            log "Skipping completed run $id"
            record "$id" SKIPPED_COMPLETE \
                "$(cat "$dir/pilot-directory.txt")" \
                "Previously completed"
            continue
            ;;
        BLOCKED_INCOMPLETE)
            fail "Incomplete evidence exists: $dir"
            ;;
        EXECUTE)
            ;;
        *)
            fail "Unknown action: $action"
            ;;
    esac

    log "========================================"
    log "Starting logical run $id"
    log "========================================"

    mkdir "$dir"
    touch "$dir/INCOMPLETE"

    kubectl -n "$NS" get pods -l "$SEL" -o wide \
        > "$dir/initial-pods.txt"

    kubectl get nodes -o wide \
        > "$dir/initial-nodes.txt"

    # Restore the designated original placement.
    log "Resetting database placement to $ORIGINAL"

    OPENMRS_CD_ALLOW_DB_RESTART=true \
    timeout "${OPENMRS_CD_RESET_TIMEOUT:-1200}" \
        "$RESET" \
        > "$dir/placement-reset.log" 2>&1 ||
        fail "Placement reset failed"

    cat "$dir/placement-reset.log"

    verify_start "$dir" ||
        fail "Starting state verification failed"

    snapshot_pilots > "$dir/pilots-before.txt"

    log "Executing C+D pilot"

    pilot_rc=0

    timeout \
        --signal=TERM \
        --kill-after=30s \
        "${RUN_TIMEOUT}s" \
        "$PILOT" \
        > "$dir/pilot-output.log" 2>&1 ||
        pilot_rc=$?

    cat "$dir/pilot-output.log"

    snapshot_pilots > "$dir/pilots-after.txt"

    mapfile -t created < <(
        comm -13 \
            "$dir/pilots-before.txt" \
            "$dir/pilots-after.txt"
    )

    [[ "${#created[@]}" -eq 1 ]] ||
        fail "Cannot identify unique pilot"

    pilot_dir="$BASE/${created[0]}"

    printf '%s\n' "$pilot_dir" \
        > "$dir/pilot-directory.txt"

    (( pilot_rc == 0 )) ||
        fail "Pilot failed: exit=$pilot_rc"

    [[ -s "$pilot_dir/controller-authority.json" ]] ||
        fail "Authority snapshot missing"

    [[ -s "$pilot_dir/controller.log" ]] ||
        fail "Controller log missing"

    grep -q '\[FENCING VERIFIED\]' \
        "$pilot_dir/controller.log" ||
        fail "Fencing not verified"

    grep -q '\[RECOVERY VERIFIED\]' \
        "$pilot_dir/controller.log" ||
        fail "Recovery not verified"

    log "Starting SSH reconciliation"

    reconcile_rc=0

    OPENMRS_CD_AUTHORITY_FILE="$pilot_dir/controller-authority.json" \
    OPENMRS_CD_RECONCILE_EVIDENCE_DIR="$dir/reconciliation-evidence" \
    timeout \
        --signal=TERM \
        --kill-after=30s \
        "${RECONCILE_TIMEOUT}s" \
        "$RECONCILE" \
        > "$dir/reconciliation.log" 2>&1 ||
        reconcile_rc=$?

    cat "$dir/reconciliation.log"

    (( reconcile_rc == 0 )) ||
        fail "Reconciliation failed: exit=$reconcile_rc"

    [[ "$(
        cat "$dir/reconciliation-evidence/outcome.txt"
    )" == RECONCILIATION_VERIFIED ]] ||
        fail "Reconciliation outcome not verified"

    read -r original_node original_ip < <(
        python3 - "$pilot_dir/controller-authority.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1]))
print(a["node"],a["ip"])
PY
    )

    [[ "$original_node" == "$ORIGINAL" ]] ||
        fail "Original worker mismatch"

    fence_inactive "$original_node" "$original_ip" ||
        fail "Final fence state not inactive"

    kubectl -n "$NS" get pods -l "$SEL" -o wide \
        > "$dir/final-pods.txt"

    kubectl get nodes -o wide \
        > "$dir/final-nodes.txt"

    date -u +%Y-%m-%dT%H:%M:%SZ \
        > "$dir/completed-at.txt"

    rm "$dir/INCOMPLETE"
    touch "$dir/COMPLETE"

    record "$id" COMPLETE "$pilot_dir" \
        "Fencing recovery reconciliation verified"

    log "Logical run $id COMPLETE"

    # The original worker is intentionally cordoned by reconciliation.
    # Restore scheduling before the next placement reset.
    kubectl uncordon "$ORIGINAL" ||
        fail "Could not uncordon original worker"

    sleep "$RESET_SECONDS"
done

log "========================================"
log "C+D CAMPAIGN FINISHED"
log "Results: $CAMPAIGN"
log "========================================"