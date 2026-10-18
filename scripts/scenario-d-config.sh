#!/usr/bin/env bash

# Failure-Aware Kubernetes
# Shared Scenario D configuration
#
# Supports legacy PostgreSQL NFS fencing and
# generalized workload-level fencing.

REPO_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
    pwd
)"

# Original PostgreSQL experiment configuration

NAMESPACE="${NAMESPACE:-failure-aware}"

POSTGRES_DEPLOYMENT="${POSTGRES_DEPLOYMENT:-fenced-postgres}"
POSTGRES_LABEL="${POSTGRES_LABEL:-app=fenced-postgres}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-fencing_test}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

# Worker configuration

WORKER1_NODE="${WORKER1_NODE:-k3s-worker1}"
WORKER2_NODE="${WORKER2_NODE:-k3s-worker2}"

WORKER1_IP="${WORKER1_IP:-102.34.160.87}"
WORKER2_IP="${WORKER2_IP:-102.34.160.103}"

WORKER1_SSH="${WORKER1_SSH:-ubuntu@${WORKER1_IP}}"
WORKER2_SSH="${WORKER2_SSH:-ubuntu@${WORKER2_IP}}"

# Storage server configuration

STORAGE_SERVER_IP="${STORAGE_SERVER_IP:-102.34.160.89}"
STORAGE_SERVER_SSH="${STORAGE_SERVER_SSH:-ubuntu@${STORAGE_SERVER_IP}}"

STORAGE_FENCE_REMOTE="${STORAGE_FENCE_REMOTE:-/usr/local/sbin/storage-fence-worker1}"

# SSH authentication

SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "ERROR: SSH private key not found: ${SSH_KEY}" >&2
    return 1 2>/dev/null || exit 1
fi

# Generalized fencing configuration

FAILURE_AWARE_FENCE_MODE="${FAILURE_AWARE_FENCE_MODE:-nfs}"

FAILURE_AWARE_FENCE_WORKER_IP="${FAILURE_AWARE_FENCE_WORKER_IP:-${WORKER1_IP}}"
FAILURE_AWARE_FENCE_NFS_PORT="${FAILURE_AWARE_FENCE_NFS_PORT:-2049}"

FAILURE_AWARE_FENCE_WORKLOAD_ID="${FAILURE_AWARE_FENCE_WORKLOAD_ID:-${NAMESPACE}/${POSTGRES_DEPLOYMENT}}"

FAILURE_AWARE_FENCE_WORKLOAD_NODE="${FAILURE_AWARE_FENCE_WORKLOAD_NODE:-${WORKER1_NODE}}"

# Independent authority agent.
# Required only for workload fencing mode.

FAILURE_AWARE_AUTHORITY_AGENT="${FAILURE_AWARE_AUTHORITY_AGENT:-}"

# SSH timeouts

FAILURE_AWARE_SSH_CONNECT_TIMEOUT="${FAILURE_AWARE_SSH_CONNECT_TIMEOUT:-5}"
FAILURE_AWARE_SSH_COMMAND_TIMEOUT="${FAILURE_AWARE_SSH_COMMAND_TIMEOUT:-45}"

# Original PostgreSQL manifests

POSTGRES_STORAGE_MANIFEST="${POSTGRES_STORAGE_MANIFEST:-${REPO_ROOT}/workloads/stateful-fencing/postgres-storage.yaml}"

POSTGRES_MANIFEST="${POSTGRES_MANIFEST:-${REPO_ROOT}/workloads/stateful-fencing/postgres.yaml}"

# Original experimental results

RESULT_ROOT="${RESULT_ROOT:-${REPO_ROOT}/experiments/evaluation/scenario-d/failure-aware}"

# Original experiment timing parameters

RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-180}"
POST_RECOVERY_SECONDS="${POST_RECOVERY_SECONDS:-10}"
OLD_AUTHORITY_STOP_TIMEOUT_SECONDS="${OLD_AUTHORITY_STOP_TIMEOUT_SECONDS:-60}"
RUNTIME_STOP_COMMAND_TIMEOUT_SECONDS="${RUNTIME_STOP_COMMAND_TIMEOUT_SECONDS:-20}"
POST_UNFENCE_SECONDS="${POST_UNFENCE_SECONDS:-15}"

# Validate fencing mode

case "${FAILURE_AWARE_FENCE_MODE}" in
    nfs|workload)
        ;;
    *)
        echo "ERROR: Unsupported fencing mode: ${FAILURE_AWARE_FENCE_MODE}" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

# Export generalized fencing settings

export FAILURE_AWARE_FENCE_MODE
export FAILURE_AWARE_FENCE_WORKER_IP
export FAILURE_AWARE_FENCE_NFS_PORT
export FAILURE_AWARE_FENCE_WORKLOAD_ID
export FAILURE_AWARE_FENCE_WORKLOAD_NODE
export FAILURE_AWARE_AUTHORITY_AGENT
export FAILURE_AWARE_SSH_CONNECT_TIMEOUT
export FAILURE_AWARE_SSH_COMMAND_TIMEOUT