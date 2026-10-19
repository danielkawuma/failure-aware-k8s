#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/scenario-d-config.sh"

RUN_NUMBER="${1:-}"

[[ "$RUN_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "Usage: $0 <completed-run-number>" >&2
    exit 2
}

NAMESPACE="failure-aware-db-test"
DEPLOYMENT="fenced-mariadb"
SELECTOR="app=fenced-mariadb"

RUN_DIR="$REPO_ROOT/experiments/evaluation/scenario-d/mariadb/run-$RUN_NUMBER"

[[ -f "$RUN_DIR/COMPLETE" ]] || {
    echo "ERROR: Completed experiment not found" >&2
    exit 1
}

ORIGINAL_NODE="$(cat "$RUN_DIR/original-node.txt")"
RECOVERY_NODE="$(cat "$RUN_DIR/recovery-node.txt")"

[[ "$ORIGINAL_NODE" == "k3s-worker3" ]] || exit 1
[[ "$RECOVERY_NODE" == "k3s-worker4" ]] || exit 1

log() {
    printf '[RECONCILE] %s\n' "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
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

old_runtime_absent() {
    local ids

    ids="$(
        ssh_node "$ORIGINAL_NODE" \
            "sudo -n k3s crictl ps \
             --label io.kubernetes.pod.namespace=$NAMESPACE \
             --label io.kubernetes.container.name=mariadb \
             -q"
    )" || return 1

    [[ -z "$ids" ]]
}

old_pods_absent() {
    kubectl get pods \
        -n "$NAMESPACE" \
        -l "$SELECTOR" \
        --field-selector="spec.nodeName=$ORIGINAL_NODE" \
        -o json |
        python3 -c '
import json,sys
data=json.load(sys.stdin)
sys.exit(0 if not data.get("items") else 1)
'
}

verify_recovery() {
    local node
    local count

    node="$(
        kubectl get deployment "$DEPLOYMENT" \
            -n "$NAMESPACE" \
            -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}'
    )"

    [[ "$node" == "$RECOVERY_NODE" ]] ||
        return 1

    count="$(
        kubectl get pods \
            -n "$NAMESPACE" \
            -l "$SELECTOR" \
            -o json |
            python3 -c '
import json,sys
items=json.load(sys.stdin).get("items",[])
ready=[
    p for p in items
    if p.get("spec",{}).get("nodeName")==sys.argv[1]
    and p.get("status",{}).get("phase")=="Running"
    and any(
        c.get("type")=="Ready" and c.get("status")=="True"
        for c in p.get("status",{}).get("conditions",[])
    )
    and not p.get("metadata",{}).get("deletionTimestamp")
]
print(len(ready))
' "$RECOVERY_NODE"
    )" || return 1

    [[ "$count" == "1" ]] || return 1

    kubectl exec \
        -n "$NAMESPACE" \
        deployment/"$DEPLOYMENT" \
        -- sh -c '
            mariadb \
              -uroot \
              -p"$MARIADB_ROOT_PASSWORD" \
              fencing_test \
              -e "SELECT 1;"
        ' >/dev/null
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
        fail "Original worker IP unavailable"
}

log "Checking recovered MariaDB"

verify_recovery ||
    fail "Recovery placement or database validation failed"

old_runtime_absent ||
    fail "Old database runtime still active or unreachable"

old_pods_absent ||
    fail "Old database Pod still exists"

configure_fence

"$SCRIPT_DIR/../storage-fence.sh" status ||
    fail "Expected NFS fence is not active"

log "Verifying old writer remains absent"

DEADLINE=$((SECONDS + 15))

while (( SECONDS < DEADLINE )); do
    old_runtime_absent ||
        fail "Old writer reappeared"

    old_pods_absent ||
        fail "Old Pod reappeared"

    sleep 2
done

log "Current workload state verified"

# Explicit approval is required because absence of a
# container does not independently guarantee that it
# cannot restart after a future partition or reboot.

if [[ "${MARIADB_RECONCILIATION_APPROVED:-}" != "true" ]]; then
    fail "Restart exclusion has not been approved; fence retained"
fi

log "Removing NFS fence"

"$SCRIPT_DIR/../storage-fence.sh" unfence ||
    fail "Unable to remove NFS fence"

sleep 5

old_runtime_absent ||
    fail "Old writer appeared after unfencing"

old_pods_absent ||
    fail "Old Pod appeared after unfencing"

verify_recovery ||
    fail "Recovered database became unavailable"

date -u +"%Y-%m-%dT%H:%M:%S.%NZ" \
    > "$RUN_DIR/reconciled-time.txt"

log "Reconciliation completed"
log "Recovered database remains operational"