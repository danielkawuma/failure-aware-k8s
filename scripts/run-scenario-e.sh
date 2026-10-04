#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

source "${SCRIPT_DIR}/experiment-config.sh"

if [[ $# -ne 2 ]]; then
    echo "Usage:"
    echo "  $0 mild 001"
    echo "  $0 moderate 001"
    echo "  $0 severe 001"
    exit 1
fi

PROFILE="$1"
RUN_NUMBER="$2"

case "${PROFILE}" in
    mild)
        PROFILE_DELAY_MS="50"
        PROFILE_JITTER_MS="10"
        PROFILE_LOSS_PERCENT="1"
        PROFILE_RATE_MBIT="10"
        ;;

    moderate)
        PROFILE_DELAY_MS="150"
        PROFILE_JITTER_MS="30"
        PROFILE_LOSS_PERCENT="3"
        PROFILE_RATE_MBIT="5"
        ;;

    severe)
        PROFILE_DELAY_MS="300"
        PROFILE_JITTER_MS="75"
        PROFILE_LOSS_PERCENT="90"
        PROFILE_RATE_MBIT=".256"
        ;;

    *)
        echo "Invalid degradation profile: ${PROFILE}"
        exit 1
        ;;
esac

SCENARIO="scenario-e"
MODE="failure-aware"

# FAULT_SECONDS="${SCENARIO_E_FAULT_SECONDS:-75}"

if [[ "${PROFILE}" == "severe" ]]; then
    FAULT_SECONDS="${SCENARIO_E_SEVERE_FAULT_SECONDS:-120}"
else
    FAULT_SECONDS="${SCENARIO_E_FAULT_SECONDS:-75}"
fi

POST_CLEAR_SECONDS="${SCENARIO_E_POST_CLEAR_SECONDS:-20}"
BASELINE_SECONDS="${SCENARIO_E_BASELINE_SECONDS:-10}"

HARNESS_CONFIG_PATH="${REPO_ROOT}/harness/config/scenario-e.json"

RUN_DIR="${REPO_ROOT}/experiments/evaluation/${SCENARIO}/${MODE}/${PROFILE}/run-${RUN_NUMBER}"

if [[ -f "${RUN_DIR}/COMPLETE" ]]; then
    echo "Run already complete:"
    echo "${RUN_DIR}"
    exit 0
fi

mkdir -p "${RUN_DIR}"

HARNESS_PID=""
CONTROLLER_PID=""
NODE_OBSERVER_PID=""
POD_OBSERVER_PID=""
FAULT_ACTIVE="false"

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

stop_observers() {
    if [[ -n "${NODE_OBSERVER_PID}" ]]; then
        kill "${NODE_OBSERVER_PID}" 2>/dev/null || true
        wait "${NODE_OBSERVER_PID}" 2>/dev/null || true
        NODE_OBSERVER_PID=""
    fi

    if [[ -n "${POD_OBSERVER_PID}" ]]; then
        kill "${POD_OBSERVER_PID}" 2>/dev/null || true
        wait "${POD_OBSERVER_PID}" 2>/dev/null || true
        POD_OBSERVER_PID=""
    fi

    if [[ -n "${HARNESS_PID}" ]]; then
        kill -INT "${HARNESS_PID}" 2>/dev/null || true
        wait "${HARNESS_PID}" 2>/dev/null || true
        HARNESS_PID=""
    fi

    if [[ -n "${CONTROLLER_PID}" ]]; then
        kill "${CONTROLLER_PID}" 2>/dev/null || true
        wait "${CONTROLLER_PID}" 2>/dev/null || true
        CONTROLLER_PID=""
    fi
}

cleanup() {
    set +e

    echo
    echo "[CLEANUP] Restoring Scenario E environment"

    if [[ "${FAULT_ACTIVE}" == "true" ]]; then
        "${SCRIPT_DIR}/fault.sh" \
          scenario-e \
          clear
    fi

    stop_observers
}

trap cleanup EXIT INT TERM

wait_node_ready() {
    local node="$1"
    local timeout="$2"
    local start
    local status

    start="$(date +%s)"

    while true; do
        status="$(
            kubectl get node \
              "${node}" \
              -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
              2>/dev/null || true
        )"

        if [[ "${status}" == "True" ]]; then
            return 0
        fi

        if (( $(date +%s) - start >= timeout )); then
            echo "Timeout waiting for ${node} Ready=True"
            return 1
        fi

        sleep 2
    done
}

get_workload_snapshot() {
    kubectl get pods \
      -n "${NAMESPACE}" \
      -l "${LABEL_SELECTOR}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"|"}{.spec.nodeName}{"|"}{.status.podIP}{"\n"}{end}' \
      2>/dev/null || true
}

workload_is_clean_on_worker1() {
    local snapshot
    local pod_count
    local line
    local name
    local phase
    local deletion_timestamp
    local node
    local pod_ip

    snapshot="$(get_workload_snapshot)"

    pod_count="$(
        printf '%s\n' "${snapshot}" \
          | sed '/^[[:space:]]*$/d' \
          | wc -l
    )"

    if [[ "${pod_count}" -ne 1 ]]; then
        return 1
    fi

    line="$(
        printf '%s\n' "${snapshot}" \
          | sed '/^[[:space:]]*$/d'
    )"

    IFS='|' read -r \
      name \
      phase \
      deletion_timestamp \
      node \
      pod_ip \
      <<< "${line}"

    [[ -n "${name}" ]] &&
    [[ "${phase}" == "Running" ]] &&
    [[ -z "${deletion_timestamp}" ]] &&
    [[ "${node}" == "${WORKER1_NODE}" ]] &&
    [[ -n "${pod_ip}" ]]
}

wait_clean_workload_worker1() {
    local timeout="$1"
    local start

    start="$(date +%s)"

    while true; do
        if workload_is_clean_on_worker1; then
            return 0
        fi

        if (( $(date +%s) - start >= timeout )); then
            echo "Timeout waiting for clean workload on ${WORKER1_NODE}"

            kubectl get pods \
              -n "${NAMESPACE}" \
              -l "${LABEL_SELECTOR}" \
              -o wide || true

            return 1
        fi

        sleep 2
    done
}

wait_http() {
    local url="$1"
    local timeout="$2"
    local start

    start="$(date +%s)"

    while true; do
        if curl \
          --silent \
          --show-error \
          --max-time 2 \
          --output /dev/null \
          --fail \
          "${url}"
        then
            return 0
        fi

        if (( $(date +%s) - start >= timeout )); then
            return 1
        fi

        sleep 2
    done
}

observe_node_status() {
    local output_file="$1"

    printf '%s\n' \
      "timestamp_utc,node,ready_status,last_transition_time" \
      > "${output_file}"

    while true; do
        timestamp="$(utc_now)"

        ready_status="$(
            kubectl get node \
              "${WORKER1_NODE}" \
              -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
              2>/dev/null || true
        )"

        transition_time="$(
            kubectl get node \
              "${WORKER1_NODE}" \
              -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' \
              2>/dev/null || true
        )"

        printf '%s,%s,%s,%s\n' \
          "${timestamp}" \
          "${WORKER1_NODE}" \
          "${ready_status}" \
          "${transition_time}" \
          >> "${output_file}"

        sleep 1
    done
}

observe_pods() {
    local output_file="$1"

    printf '%s\n' \
      "timestamp_utc,pod,phase,node,pod_ip,deletion_timestamp" \
      > "${output_file}"

    while true; do
        timestamp="$(utc_now)"

        kubectl get pods \
          -n "${NAMESPACE}" \
          -l "${LABEL_SELECTOR}" \
          -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"|"}{.status.podIP}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}' \
          2>/dev/null \
          | while IFS='|' read -r \
              pod \
              phase \
              node \
              pod_ip \
              deletion_timestamp
            do
                if [[ -z "${pod}" ]]; then
                    continue
                fi

                printf '%s,%s,%s,%s,%s,%s\n' \
                  "${timestamp}" \
                  "${pod}" \
                  "${phase}" \
                  "${node}" \
                  "${pod_ip}" \
                  "${deletion_timestamp}" \
                  >> "${output_file}"
            done

        sleep 1
    done
}

echo
echo "=========================================="
echo "Scenario E degraded-network run"
echo "Profile : ${PROFILE}"
echo "Mode    : ${MODE}"
echo "Run     : ${RUN_NUMBER}"
echo "=========================================="
echo

echo "[1/9] Clearing stale faults"

"${SCRIPT_DIR}/fault.sh" clear-all || true

echo "[2/9] Waiting for nodes"

wait_node_ready "${WORKER1_NODE}" 120
wait_node_ready "${WORKER2_NODE}" 120

echo "[3/9] Applying Failure-Aware workload"

kubectl apply \
  -f "${FA_MANIFEST}"

kubectl rollout status \
  deployment/baseline-web \
  -n "${NAMESPACE}" \
  --timeout=120s

if ! workload_is_clean_on_worker1; then
    echo "Recreating the baseline workload on Worker1"

    kubectl delete pod \
      -n "${NAMESPACE}" \
      -l "${LABEL_SELECTOR}" \
      --wait=true \
      --timeout=120s \
      || true
fi

wait_clean_workload_worker1 120

ORIGINAL_POD="$(
    get_workload_snapshot \
      | sed '/^[[:space:]]*$/d' \
      | head -n 1 \
      | cut -d'|' -f1
)"

ORIGINAL_POD_IP="$(
    get_workload_snapshot \
      | sed '/^[[:space:]]*$/d' \
      | head -n 1 \
      | cut -d'|' -f5
)"

echo "Original Pod : ${ORIGINAL_POD}"
echo "Original Node: ${WORKER1_NODE}"

echo "[4/9] Verifying healthy initial state"

wait_http \
  "http://${WORKER1_IP}:${NODEPORT}" \
  60

kubectl get pods \
  -n "${NAMESPACE}" \
  -l "${LABEL_SELECTOR}" \
  -o wide \
  > "${RUN_DIR}/pods-before.txt"

kubectl get nodes \
  -o wide \
  > "${RUN_DIR}/nodes-before.txt"

echo "[5/9] Starting harness, controller and observers"

HARNESS_CONFIG="${HARNESS_CONFIG_PATH}" \
"${HARNESS_BINARY}" \
  > "${RUN_DIR}/harness.log" \
  2>&1 &

HARNESS_PID=$!

(
    cd "${REPO_ROOT}"
    "${CONTROLLER_BINARY}"
) \
  > "${RUN_DIR}/controller.log" \
  2>&1 &

CONTROLLER_PID=$!

observe_node_status \
  "${RUN_DIR}/node-status-observations.csv" &

NODE_OBSERVER_PID=$!

observe_pods \
  "${RUN_DIR}/pod-observations.csv" &

POD_OBSERVER_PID=$!

echo "Baseline observation window: ${BASELINE_SECONDS}s"

sleep "${BASELINE_SECONDS}"

RUN_START="$(utc_now)"

cat > "${RUN_DIR}/experiment-metadata.json" <<EOF
{
  "scenario": "scenario-e",
  "mode": "failure-aware",
  "profile": "${PROFILE}",
  "run_number": "${RUN_NUMBER}",
  "run_start_utc": "${RUN_START}",
  "original_pod": "${ORIGINAL_POD}",
  "original_pod_ip": "${ORIGINAL_POD_IP}",
  "original_node": "${WORKER1_NODE}",
  "api_server_ip": "${API_SERVER_IP}",
  "api_server_port": ${API_SERVER_PORT},
  "network_interface": "ens3",
  "delay_ms": ${PROFILE_DELAY_MS},
  "jitter_ms": ${PROFILE_JITTER_MS},
  "packet_loss_percent": ${PROFILE_LOSS_PERCENT},
  "rate_mbit": ${PROFILE_RATE_MBIT},
  "fault_duration_seconds": ${FAULT_SECONDS}
}
EOF

echo "[6/9] Applying ${PROFILE} API-path degradation"

FAULT_TIME="$(utc_now)"

printf '%s\n' \
  "${FAULT_TIME}" \
  > "${RUN_DIR}/fault-time.txt"

"${SCRIPT_DIR}/fault.sh" \
  scenario-e \
  apply \
  "${PROFILE}"

FAULT_ACTIVE="true"

"${SCRIPT_DIR}/fault.sh" \
  scenario-e \
  show \
  > "${RUN_DIR}/traffic-control-during-fault.txt"

echo "[7/9] Holding degradation for ${FAULT_SECONDS}s"

sleep "${FAULT_SECONDS}"

echo "[8/9] Clearing network degradation"

FAULT_CLEAR_TIME="$(utc_now)"

printf '%s\n' \
  "${FAULT_CLEAR_TIME}" \
  > "${RUN_DIR}/fault-clear-time.txt"

"${SCRIPT_DIR}/fault.sh" \
  scenario-e \
  clear

FAULT_ACTIVE="false"

"${SCRIPT_DIR}/fault.sh" \
  scenario-e \
  show \
  > "${RUN_DIR}/traffic-control-after-clear.txt"

echo "Post-clear observation window: ${POST_CLEAR_SECONDS}s"

sleep "${POST_CLEAR_SECONDS}"

echo "[9/9] Stopping observers"

stop_observers

kubectl get pods \
  -n "${NAMESPACE}" \
  -l "${LABEL_SELECTOR}" \
  -o wide \
  > "${RUN_DIR}/pods-after.txt"

kubectl get nodes \
  -o wide \
  > "${RUN_DIR}/nodes-after.txt"

HARNESS_RUN_ROOT="${REPO_ROOT}/experiments/baseline/scenario-e/runs"

LATEST_HARNESS_RUN="$(
    ls -1dt \
      "${HARNESS_RUN_ROOT}"/run-* \
      2>/dev/null \
      | head -n 1 \
      || true
)"

if [[ -n "${LATEST_HARNESS_RUN}" ]]; then
    cp -a \
      "${LATEST_HARNESS_RUN}/." \
      "${RUN_DIR}/"
else
    echo "WARNING: no Scenario E harness run directory found"
fi

REPLACEMENT_COUNT="$(
    awk \
      -F',' \
      -v original="${ORIGINAL_POD}" \
      '
      NR > 1 && $2 != "" && $2 != original {
          observed[$2] = 1
      }
      END {
          print length(observed)
      }
      ' \
      "${RUN_DIR}/pod-observations.csv"
)"

NODE_UNKNOWN_OBSERVED="false"

if awk \
  -F',' \
  '
  NR > 1 && $3 == "Unknown" {
      found = 1
  }
  END {
      exit(found ? 0 : 1)
  }
  ' \
  "${RUN_DIR}/node-status-observations.csv"
then
    NODE_UNKNOWN_OBSERVED="true"
fi

ORIGINAL_POD_PRESENT="false"

if kubectl get pod \
  "${ORIGINAL_POD}" \
  -n "${NAMESPACE}" \
  >/dev/null 2>&1
then
    ORIGINAL_POD_PRESENT="true"
fi

cat > "${RUN_DIR}/scenario-e-outcome.json" <<EOF
{
  "profile": "${PROFILE}",
  "node_unknown_observed": ${NODE_UNKNOWN_OBSERVED},
  "replacement_count": ${REPLACEMENT_COUNT},
  "original_pod_present_after_degradation": ${ORIGINAL_POD_PRESENT}
}
EOF

touch "${RUN_DIR}/COMPLETE"

trap - EXIT INT TERM

echo
echo "=========================================="
echo "SCENARIO E RUN COMPLETE"
echo "Profile            : ${PROFILE}"
echo "Node Unknown seen  : ${NODE_UNKNOWN_OBSERVED}"
echo "Replacement count  : ${REPLACEMENT_COUNT}"
echo "Original Pod exists: ${ORIGINAL_POD_PRESENT}"
echo "Results            : ${RUN_DIR}"
echo "=========================================="