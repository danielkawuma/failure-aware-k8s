#!/usr/bin/env bash

REPO_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"

NAMESPACE="failure-aware"

POSTGRES_DEPLOYMENT="fenced-postgres"
POSTGRES_LABEL="app=fenced-postgres"
POSTGRES_DATABASE="fencing_test"
POSTGRES_USER="postgres"

WORKER1_NODE="k3s-worker1"
WORKER2_NODE="k3s-worker2"

WORKER1_IP="102.34.160.87"
WORKER2_IP="102.34.160.103"

WORKER1_SSH="ubuntu@102.34.160.87"

STORAGE_SERVER_IP="102.34.160.89"
STORAGE_SERVER_SSH="ubuntu@102.34.160.89"

SSH_KEY="${SSH_KEY:-}"

if [[ -z "${SSH_KEY}" ]]; then
    echo "ERROR: SSH_KEY is not configured."
    echo 'Set it using: export SSH_KEY="$HOME/.ssh/<your-private-key>"'
    exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "ERROR: SSH private key not found: ${SSH_KEY}"
    exit 1
fi

STORAGE_FENCE_REMOTE="/usr/local/sbin/storage-fence-worker1"

POSTGRES_STORAGE_MANIFEST="${REPO_ROOT}/workloads/stateful-fencing/postgres-storage.yaml"

POSTGRES_MANIFEST="${REPO_ROOT}/workloads/stateful-fencing/postgres.yaml"

RESULT_ROOT="${REPO_ROOT}/experiments/evaluation/scenario-d/failure-aware"

RECOVERY_TIMEOUT_SECONDS="180"

POST_RECOVERY_SECONDS="10"

OLD_AUTHORITY_STOP_TIMEOUT_SECONDS="60"

RUNTIME_STOP_COMMAND_TIMEOUT_SECONDS="20"

POST_UNFENCE_SECONDS="15"