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

#
# Storage server used for Scenario D
#
STORAGE_SERVER_IP="102.34.160.89"
STORAGE_SERVER_SSH="ubuntu@102.34.160.89"

#
# SSH key is supplied locally.
#
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

#
# Installed storage-fencing backend on the storage server.
#
STORAGE_FENCE_REMOTE="/usr/local/sbin/storage-fence-worker1"

#
# Scenario D workload manifests.
#
POSTGRES_STORAGE_MANIFEST="${REPO_ROOT}/workloads/stateful-fencing/postgres-storage.yaml"

POSTGRES_MANIFEST="${REPO_ROOT}/workloads/stateful-fencing/postgres.yaml"

#
# Scenario D result location.
#
RESULT_ROOT="${REPO_ROOT}/experiments/evaluation/scenario-d/failure-aware"

#
# Maximum time to wait for PostgreSQL recovery on Worker2.
#
RECOVERY_TIMEOUT_SECONDS="180"

#
# Additional observation time after recovery.
#
POST_RECOVERY_SECONDS="10"