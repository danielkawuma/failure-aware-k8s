#!/usr/bin/env bash

REPO_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"

NAMESPACE="failure-aware"
LABEL_SELECTOR="app=baseline-web"

WORKER1_NODE="k3s-worker1"
WORKER2_NODE="k3s-worker2"

WORKER1_IP="102.34.160.87"
WORKER2_IP="102.34.160.103"

WORKER1_SSH="ubuntu@102.34.160.87"

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

API_SERVER_IP="102.34.160.89"
API_SERVER_PORT="6443"

NODEPORT="30364"

#
# Allow the experiment to establish a healthy observation
# period before fault injection.
#
BASELINE_SECONDS="10"

#
# Scenario B must be held beyond the normal native
# Kubernetes eviction period.
#
# SCENARIO_B_FAULT_SECONDS="360"
SCENARIO_B_FAULT_SECONDS="90"

#
# Scenario C waits for service recovery on Worker2.
#
SCENARIO_C_TIMEOUT_SECONDS="420"

#
# Continue observing after fault clearance.
#
POST_CLEAR_SECONDS="20"

HARNESS_BINARY="${REPO_ROOT}/harness/target/debug/failure-aware-harness"

CONTROLLER_BINARY="${REPO_ROOT}/controller/target/debug/failure-aware-controller"

FA_MANIFEST="${REPO_ROOT}/workloads/test-workload/nginx.yaml"

NATIVE_MANIFEST="${REPO_ROOT}/workloads/test-workload/nginx-native.yaml"

SCENARIO_B_CONFIG="${REPO_ROOT}/harness/config/scenario-b.json"

SCENARIO_C_CONFIG="${REPO_ROOT}/harness/config/scenario-c.json"