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

WORKER1_SSH="ubuntu@${WORKER1_IP}"

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

BASELINE_SECONDS="${BASELINE_SECONDS:-10}"
SCENARIO_B_FAULT_SECONDS="${SCENARIO_B_FAULT_SECONDS:-360}"
SCENARIO_C_TIMEOUT_SECONDS="${SCENARIO_C_TIMEOUT_SECONDS:-420}"
POST_CLEAR_SECONDS="${POST_CLEAR_SECONDS:-20}"

SCENARIO_E_FAULT_SECONDS="${SCENARIO_E_FAULT_SECONDS:-75}"
SCENARIO_E_SEVERE_FAULT_SECONDS="${SCENARIO_E_SEVERE_FAULT_SECONDS:-120}"
SCENARIO_E_POST_CLEAR_SECONDS="${SCENARIO_E_POST_CLEAR_SECONDS:-20}"
SCENARIO_E_BASELINE_SECONDS="${SCENARIO_E_BASELINE_SECONDS:-10}"

HARNESS_BINARY="${REPO_ROOT}/harness/target/debug/failure-aware-harness"
CONTROLLER_BINARY="${REPO_ROOT}/controller/target/debug/failure-aware-controller"

FA_MANIFEST="${REPO_ROOT}/workloads/test-workload/nginx.yaml"
NATIVE_MANIFEST="${REPO_ROOT}/workloads/test-workload/nginx-native.yaml"

SCENARIO_B_CONFIG="${REPO_ROOT}/harness/config/scenario-b.json"
SCENARIO_C_CONFIG="${REPO_ROOT}/harness/config/scenario-c.json"
SCENARIO_E_CONFIG="${REPO_ROOT}/harness/config/scenario-e.json"
