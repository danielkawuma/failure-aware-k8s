#!/usr/bin/env bash
set -euo pipefail

# Failure-Aware Kubernetes fencing backend.
#
# Modes:
#   nfs      - Legacy worker-wide NFS fencing (Scenario D compatibility).
#   workload - Delegates to an independently managed, workload-scoped
#              authority-fencing agent.
#
# This script is normally executed on the NFS/management server.
#
# IMPORTANT:
# Workload mode must not return success until the independent agent
# verifies that the old writer cannot resume authoritative writes,
# including after worker reconnection or restart.
#
# A Kubernetes Pod deletion or container stop is not sufficient proof.

ACTION="${1:-}"
MODE="${FAILURE_AWARE_FENCE_MODE:-nfs}"

WORKER_IP="${FAILURE_AWARE_FENCE_WORKER_IP:-102.34.160.87}"
NFS_PORT="${FAILURE_AWARE_FENCE_NFS_PORT:-2049}"

WORKLOAD_ID="${FAILURE_AWARE_FENCE_WORKLOAD_ID:-}"
WORKLOAD_NODE="${FAILURE_AWARE_FENCE_WORKLOAD_NODE:-}"

AUTHORITY_AGENT="${FAILURE_AWARE_AUTHORITY_AGENT:-}"

log() {
    printf '[FENCING] %s\n' "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage:
  storage-fence-worker1 fence
  storage-fence-worker1 status
  storage-fence-worker1 unfence

Environment:
  FAILURE_AWARE_FENCE_MODE=nfs|workload

Legacy NFS mode:
  FAILURE_AWARE_FENCE_WORKER_IP
  FAILURE_AWARE_FENCE_NFS_PORT

Workload mode:
  FAILURE_AWARE_FENCE_WORKLOAD_ID
  FAILURE_AWARE_FENCE_WORKLOAD_NODE
  FAILURE_AWARE_AUTHORITY_AGENT

Workload mode requires an independently managed authority agent.
EOF
}

case "$ACTION" in
    fence|status|unfence)
        ;;
    *)
        usage
        exit 2
        ;;
esac

case "$MODE" in
    nfs|workload)
        ;;
    *)
        fail "Unsupported fencing mode: $MODE"
        ;;
esac

validate_worker_ip() {
    if [[ ! "$WORKER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "Invalid worker IPv4 address"
    fi

    local octet

    IFS='.' read -r -a octets <<< "$WORKER_IP"

    for octet in "${octets[@]}"; do
        if (( 10#$octet > 255 )); then
            fail "Invalid worker IPv4 address"
        fi
    done
}

validate_port() {
    if [[ ! "$NFS_PORT" =~ ^[0-9]+$ ]]; then
        fail "Invalid NFS port"
    fi

    if (( NFS_PORT < 1 || NFS_PORT > 65535 )); then
        fail "NFS port outside valid range"
    fi
}

nfs_rule_exists() {
    iptables -C INPUT \
        -s "$WORKER_IP" \
        -p tcp \
        --dport "$NFS_PORT" \
        -j DROP \
        2>/dev/null
}

nfs_fence() {
    log "Applying legacy NFS fence"
    log "Worker=$WORKER_IP Port=$NFS_PORT"

    if ! nfs_rule_exists; then
        iptables -I INPUT 1 \
            -s "$WORKER_IP" \
            -p tcp \
            --dport "$NFS_PORT" \
            -j DROP
    fi

    if ! nfs_rule_exists; then
        fail "NFS firewall rule could not be verified"
    fi

    log "Legacy NFS fence active"
}

nfs_status() {
    if nfs_rule_exists; then
        echo "FENCED"
        exit 0
    fi

    echo "NOT_FENCED"
    exit 1
}

nfs_unfence() {
    log "Removing legacy NFS fence"

    while nfs_rule_exists; do
        iptables -D INPUT \
            -s "$WORKER_IP" \
            -p tcp \
            --dport "$NFS_PORT" \
            -j DROP
    done

    if nfs_rule_exists; then
        fail "NFS firewall rule remains active"
    fi

    log "Legacy NFS fence removed"
}

validate_workload_target() {
    [[ -n "$WORKLOAD_ID" ]] ||
        fail "FAILURE_AWARE_FENCE_WORKLOAD_ID is required"

    [[ -n "$WORKLOAD_NODE" ]] ||
        fail "FAILURE_AWARE_FENCE_WORKLOAD_NODE is required"

    # Restrict target identifiers to predictable characters.
    [[ "$WORKLOAD_ID" =~ ^[a-zA-Z0-9._:/-]+$ ]] ||
        fail "Invalid workload identifier"

    [[ "$WORKLOAD_NODE" =~ ^[a-zA-Z0-9._-]+$ ]] ||
        fail "Invalid workload node"
}

validate_authority_agent() {
    [[ -n "$AUTHORITY_AGENT" ]] ||
        fail "No independent authority agent configured"

    [[ "$AUTHORITY_AGENT" = /* ]] ||
        fail "Authority agent must be an absolute path"

    [[ -f "$AUTHORITY_AGENT" ]] ||
        fail "Authority agent does not exist"

    [[ -x "$AUTHORITY_AGENT" ]] ||
        fail "Authority agent is not executable"
}

run_authority_agent() {
    local operation="$1"

    validate_workload_target
    validate_authority_agent

    log "mode=workload action=$operation workload=$WORKLOAD_ID node=$WORKLOAD_NODE"

    # The agent must implement durable authority revocation.
    #
    # A successful exit must mean that the requested authority state
    # has been independently verified, not merely that an operation
    # was submitted.
    #
    # This interface intentionally does not prescribe a database engine.
    "$AUTHORITY_AGENT" \
        "$operation" \
        "$WORKLOAD_ID" \
        "$WORKLOAD_NODE"
}

workload_fence() {
    run_authority_agent fence

    # Recheck the independently enforced state.
    # The agent's status operation must return success only if
    # old-writer authority is durably revoked.
    if ! run_authority_agent status; then
        fail "Workload authority exclusion could not be verified"
    fi

    log "Workload authority exclusion verified"
}

workload_status() {
    if run_authority_agent status; then
        echo "FENCED"
        exit 0
    fi

    echo "NOT_FENCED"
    exit 1
}

workload_unfence() {
    # Unfencing must not automatically grant write authority.
    #
    # The independent agent is responsible for ensuring that
    # an old writer cannot resume after authority transfer.
    #
    # If the agent cannot prove that releasing exclusion is safe,
    # it must return a nonzero status.
    run_authority_agent unfence

    log "Workload exclusion release completed"
}

case "$MODE:$ACTION" in
    nfs:fence)
        validate_worker_ip
        validate_port
        nfs_fence
        ;;

    nfs:status)
        validate_worker_ip
        validate_port
        nfs_status
        ;;

    nfs:unfence)
        validate_worker_ip
        validate_port
        nfs_unfence
        ;;

    workload:fence)
        workload_fence
        ;;

    workload:status)
        workload_status
        ;;

    workload:unfence)
        workload_unfence
        ;;
esac