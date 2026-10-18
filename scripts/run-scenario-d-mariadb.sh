#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/scenario-d-config.sh"

RUN_NUMBER="${1:-}"
[[ "$RUN_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "Usage: $0 <run-number>" >&2
    exit 2
}

NAMESPACE="failure-aware-db-test"
DEPLOYMENT="fenced-mariadb"
SELECTOR="app=fenced-mariadb"
CONTAINER="mariadb"
DATABASE="fencing_test"
EXPECTED_ORIGINAL="k3s-worker3"
RECOVERY_NODE="${MARIADB_RECOVERY_NODE:-k3s-worker4}"

RESULT_ROOT="$REPO_ROOT/experiments/evaluation/scenario-d/mariadb"
RUN_DIR="$RESULT_ROOT/run-$RUN_NUMBER"

[[ ! -e "$RUN_DIR" ]] || {
    echo "ERROR: Results already exist: $RUN_DIR" >&2
    exit 1
}

mkdir -p "$RUN_DIR"

FENCE_ATTEMPTED=false
FENCE_VERIFIED=false
RECOVERY_RELEASED=false
ORIGINAL_NODE=""
ORIGINAL_POD=""
RECOVERY_POD=""

now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
}

log() {
    printf '[%s] %s\n' "$(now)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

timestamp() {
    now > "$RUN_DIR/$1"
}

node_ip() {
    kubectl get node "$1" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

ssh_node() {
    local ip
    ip="$(node_ip "$1")"
    [[ -n "$ip" ]] || return 1
    shift

    timeout 25 ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "ubuntu@$ip" "$@"
}

runtime_ids() {
    ssh_node "$1" \
        "sudo -n k3s crictl ps \
        --label io.kubernetes.pod.namespace=$NAMESPACE \
        --label io.kubernetes.container.name=$CONTAINER \
        -q"
}

old_runtime_absent() {
    local ids
    ids="$(runtime_ids "$ORIGINAL_NODE")" || return 1
    [[ -z "$ids" ]]
}

pods_on_node() {
    kubectl get pods \
        -n "$NAMESPACE" \
        -l "$SELECTOR" \
        --field-selector="spec.nodeName=$1" \
        -o json
}

no_old_pods() {
    pods_on_node "$ORIGINAL_NODE" |
        python3 -c '
import json,sys
data=json.load(sys.stdin)
sys.exit(0 if not data.get("items") else 1)
'
}

single_running_pod() {
    kubectl get pods \
        -n "$NAMESPACE" \
        -l "$SELECTOR" \
        -o json |
        python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[])
items=[
    p for p in items
    if p.get("status",{}).get("phase")=="Running"
    and not p.get("metadata",{}).get("deletionTimestamp")
]
if len(items)!=1:
    sys.exit(1)
p=items[0]
print(p["metadata"]["name"])
print(p["spec"].get("nodeName",""))
'
}

sql() {
    local pod="$1"
    local statement="$2"

    timeout 20 kubectl exec \
        -n "$NAMESPACE" \
        "$pod" \
        -- sh -c '
            exec mariadb \
              -uroot \
              -p"$MARIADB_ROOT_PASSWORD" \
              fencing_test \
              --batch \
              --skip-column-names \
              -e "$1"
        ' sh "$statement"
}

marker_count() {
    sql "$1" \
        "SELECT COUNT(*) FROM scenario_d_fence_test
         WHERE marker='$2';" |
        tr -d '[:space:]'
}

wait_database() {
    local expected_node="$1"
    local deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))
    local details pod node

    while (( SECONDS < deadline )); do
        if details="$(single_running_pod 2>/dev/null)"; then
            pod="$(sed -n '1p' <<< "$details")"
            node="$(sed -n '2p' <<< "$details")"

            if [[ "$node" == "$expected_node" ]] &&
               sql "$pod" "SELECT 1;" >/dev/null 2>&1
            then
                printf '%s\n' "$pod"
                return 0
            fi
        fi
        sleep 2
    done

    return 1
}

set_placement() {
    kubectl patch deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        --type=merge \
        -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {
                  \"kubernetes.io/hostname\": \"$1\"
                }
              }
            }
          }
        }"
}

configure_fence() {
    export FAILURE_AWARE_FENCE_MODE=nfs
    export FAILURE_AWARE_FENCE_WORKER_IP
    export FAILURE_AWARE_FENCE_WORKLOAD_ID
    export FAILURE_AWARE_FENCE_WORKLOAD_NODE

    FAILURE_AWARE_FENCE_WORKER_IP="$(node_ip "$ORIGINAL_NODE")"
    FAILURE_AWARE_FENCE_WORKLOAD_ID="$NAMESPACE/$DEPLOYMENT"
    FAILURE_AWARE_FENCE_WORKLOAD_NODE="$ORIGINAL_NODE"

    [[ -n "$FAILURE_AWARE_FENCE_WORKER_IP" ]] ||
        fail "Cannot resolve original worker IP"
}

cleanup() {
    local rc=$?
    trap - EXIT

    if [[ "$FENCE_ATTEMPTED" == true ]]; then
        log "Fence may be active on $ORIGINAL_NODE."
        log "Do not remove it automatically."
        printf '%s\n' "$ORIGINAL_NODE" \
            > "$RUN_DIR/fenced-node.txt"
    fi

    if (( rc != 0 )); then
        log "Pilot failed; evidence retained in $RUN_DIR"
    fi

    exit "$rc"
}

trap cleanup EXIT

log "Starting disposable MariaDB Scenario D run $RUN_NUMBER"

# --------------------------------------------------
# Preflight: restrict the experiment to disposable data.
# --------------------------------------------------

kubectl get namespace "$NAMESPACE" >/dev/null

kubectl get deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" >/dev/null

CLAIM="$(
    kubectl get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.volumes[0].persistentVolumeClaim.claimName}'
)"

[[ "$CLAIM" == "mariadb-fencing-pvc" ]] ||
    fail "Unexpected PVC: $CLAIM"

CLASS="$(
    kubectl get pvc "$CLAIM" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.storageClassName}'
)"

[[ "$CLASS" == "nfs-client" ]] ||
    fail "Expected disposable NFS PVC"

LABEL="$(
    kubectl get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.metadata.labels.failure-aware\.io/duplication-sensitive}'
)"

[[ "$LABEL" == "true" ]] ||
    fail "Duplication-sensitive label missing"

REPLICAS="$(
    kubectl get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}'
)"

[[ "$REPLICAS" == "1" ]] ||
    fail "Expected exactly one replica"

DETAILS="$(single_running_pod)" ||
    fail "Expected one running database Pod"

ORIGINAL_POD="$(sed -n '1p' <<< "$DETAILS")"
ORIGINAL_NODE="$(sed -n '2p' <<< "$DETAILS")"

[[ "$ORIGINAL_NODE" == "$EXPECTED_ORIGINAL" ]] ||
    fail "Pilot restricted to $EXPECTED_ORIGINAL"

[[ "$RECOVERY_NODE" != "$ORIGINAL_NODE" ]] ||
    fail "Recovery node equals original node"

kubectl get node "$RECOVERY_NODE" >/dev/null

configure_fence

# Never begin with an existing fence.
if "$SCRIPT_DIR/storage-fence.sh" status >/dev/null 2>&1; then
    fail "Existing fence detected; reconcile before another run"
fi

# Verify independent runtime access.
runtime_ids "$ORIGINAL_NODE" >/dev/null ||
    fail "Cannot inspect original container runtime"

# Check for other active NFS consumers.
# A shared NFS mount belonging to another Pod makes
# worker-wide fencing unsafe for this pilot.
OTHER_NFS="$(
    ssh_node "$ORIGINAL_NODE" \
        "findmnt -rn -t nfs,nfs4 -o SOURCE" |
        grep -v 'failure-aware-db-test-mariadb-fencing-pvc-' || true
)"

[[ -z "$OTHER_NFS" ]] ||
    fail "Other NFS mounts detected on original worker"

log "Original Pod: $ORIGINAL_POD"
log "Original Node: $ORIGINAL_NODE"
log "Recovery Node: $RECOVERY_NODE"

printf '%s\n' "$ORIGINAL_POD" > "$RUN_DIR/original-pod.txt"
printf '%s\n' "$ORIGINAL_NODE" > "$RUN_DIR/original-node.txt"

# --------------------------------------------------
# Verify original database authority.
# --------------------------------------------------

sql "$ORIGINAL_POD" "
CREATE TABLE IF NOT EXISTS scenario_d_fence_test (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    marker VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
"

PRE_MARKER="mariadb-pre-$RUN_NUMBER"
RECOVERY_MARKER="mariadb-recovery-$RUN_NUMBER"

sql "$ORIGINAL_POD" \
    "INSERT IGNORE INTO scenario_d_fence_test(marker)
     VALUES ('$PRE_MARKER');"

[[ "$(marker_count "$ORIGINAL_POD" "$PRE_MARKER")" == "1" ]] ||
    fail "Pre-fence write failed"

timestamp "pre-fence-write-time.txt"

# --------------------------------------------------
# Quiesce the original writer before fencing.
# --------------------------------------------------

log "Scaling disposable database to zero"

timestamp "old-authority-stop-start-time.txt"

kubectl scale deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" \
    --replicas=0

DEADLINE=$((SECONDS + OLD_AUTHORITY_STOP_TIMEOUT_SECONDS))
STOPPED=false

while (( SECONDS < DEADLINE )); do
    if old_runtime_absent && no_old_pods; then
        STOPPED=true
        break
    fi
    sleep 2
done

[[ "$STOPPED" == true ]] ||
    fail "Old authority not fully terminated"

timestamp "old-authority-stopped-time.txt"

log "Original database termination verified"

# --------------------------------------------------
# Apply and verify the NFS fence.
# --------------------------------------------------

log "Applying NFS fence to $ORIGINAL_NODE"

FENCE_ATTEMPTED=true
timestamp "fence-start-time.txt"

"$SCRIPT_DIR/storage-fence.sh" fence ||
    fail "Fence operation failed or was not verified"

"$SCRIPT_DIR/storage-fence.sh" status ||
    fail "Fence status verification failed"

FENCE_VERIFIED=true
timestamp "fence-complete-time.txt"

old_runtime_absent ||
    fail "Old database container reappeared"

no_old_pods ||
    fail "Old database Pod reappeared"

# --------------------------------------------------
# Release recovery on the selected worker.
# --------------------------------------------------

log "Releasing recovery on $RECOVERY_NODE"

set_placement "$RECOVERY_NODE"
timestamp "recovery-release-time.txt"

RECOVERY_RELEASED=true

kubectl scale deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" \
    --replicas=1

RECOVERY_POD="$(wait_database "$RECOVERY_NODE")" ||
    fail "Recovery timed out"

timestamp "service-restored-time.txt"

printf '%s\n' "$RECOVERY_POD" > "$RUN_DIR/recovery-pod.txt"
printf '%s\n' "$RECOVERY_NODE" > "$RUN_DIR/recovery-node.txt"

# --------------------------------------------------
# Verify data integrity.
# --------------------------------------------------

[[ "$(marker_count "$RECOVERY_POD" "$PRE_MARKER")" == "1" ]] ||
    fail "Pre-fence marker not preserved"

sql "$RECOVERY_POD" \
    "INSERT IGNORE INTO scenario_d_fence_test(marker)
     VALUES ('$RECOVERY_MARKER');"

[[ "$(marker_count "$RECOVERY_POD" "$RECOVERY_MARKER")" == "1" ]] ||
    fail "Recovery write failed"

old_runtime_absent ||
    fail "Old writer reappeared"

no_old_pods ||
    fail "Old database Pod reappeared"

"$SCRIPT_DIR/storage-fence.sh" status ||
    fail "Fence no longer active"

cat > "$RUN_DIR/experiment-metadata.json" <<EOF
{
  "scenario": "scenario-d",
  "database_engine": "mariadb",
  "run_number": "$RUN_NUMBER",
  "original_node": "$ORIGINAL_NODE",
  "original_pod": "$ORIGINAL_POD",
  "recovery_node": "$RECOVERY_NODE",
  "recovery_pod": "$RECOVERY_POD",
  "fencing_mechanism": "ordered-stop-then-worker-nfs-denial",
  "fence_verified": true,
  "pre_fence_data_preserved": true,
  "recovery_write_committed": true,
  "fence_retained": true,
  "experiment_type": "controlled-stop-before-fence"
}
EOF

touch "$RUN_DIR/COMPLETE"

log "MariaDB Scenario D pilot completed"
log "Results: $RUN_DIR"
log "NFS fence retained pending reconciliation"