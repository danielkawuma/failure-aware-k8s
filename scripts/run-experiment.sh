#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

source "${SCRIPT_DIR}/experiment-config.sh"

if [[ $# -ne 3 ]]; then
    echo "Usage:"
    echo "  $0 scenario-b native 001"
    echo "  $0 scenario-b failure-aware 001"
    echo "  $0 scenario-c native 001"
    echo "  $0 scenario-c failure-aware 001"
    exit 1
fi

SCENARIO="$1"
MODE="$2"
RUN_NUMBER="$3"

if [[ "${SCENARIO}" != "scenario-b" &&
      "${SCENARIO}" != "scenario-c" ]]
then
    echo "Invalid scenario: ${SCENARIO}"
    exit 1
fi

if [[ "${MODE}" != "native" &&
      "${MODE}" != "failure-aware" ]]
then
    echo "Invalid mode: ${MODE}"
    exit 1
fi

RUN_DIR="${REPO_ROOT}/experiments/evaluation/${SCENARIO}/${MODE}/run-${RUN_NUMBER}"

if [[ -f "${RUN_DIR}/COMPLETE" ]]; then
    echo "Run already complete:"
    echo "${RUN_DIR}"
    exit 0
fi

mkdir -p "${RUN_DIR}"

HARNESS_PID=""
CONTROLLER_PID=""
FAULT_ACTIVE="false"

cleanup() {
    set +e

    echo
    echo "[CLEANUP] Restoring experiment environment"

    if [[ "${FAULT_ACTIVE}" == "true" ]]; then
        "${SCRIPT_DIR}/fault.sh" \
          "${SCENARIO}" \
          clear
    fi

    if [[ -n "${HARNESS_PID}" ]]; then
        kill -INT \
          "${HARNESS_PID}" \
          2>/dev/null

        wait \
          "${HARNESS_PID}" \
          2>/dev/null
    fi

    if [[ -n "${CONTROLLER_PID}" ]]; then
        kill \
          "${CONTROLLER_PID}" \
          2>/dev/null

        wait \
          "${CONTROLLER_PID}" \
          2>/dev/null
    fi
}

trap cleanup EXIT INT TERM

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

wait_node_ready() {
    local node="$1"
    local timeout="${2:-120}"

    local start
    start="$(date +%s)"

    while true; do
        local status

        status="$(
            kubectl get node \
              "${node}" \
              -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
              2>/dev/null \
              || true
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
      2>/dev/null \
      || true
}

workload_is_clean_on_worker1() {
    local snapshot

    snapshot="$(
        get_workload_snapshot
    )"

    local pod_count

    pod_count="$(
        printf '%s\n' "${snapshot}" \
          | sed '/^[[:space:]]*$/d' \
          | wc -l
    )"

    if [[ "${pod_count}" -ne 1 ]]; then
        return 1
    fi

    local line

    line="$(
        printf '%s\n' "${snapshot}" \
          | sed '/^[[:space:]]*$/d'
    )"

    local name
    local phase
    local deletion_timestamp
    local node
    local pod_ip

    IFS='|' read -r \
        name \
        phase \
        deletion_timestamp \
        node \
        pod_ip \
        <<< "${line}"

    if [[ -z "${name}" ]]; then
        return 1
    fi

    if [[ "${phase}" != "Running" ]]; then
        return 1
    fi

    if [[ -n "${deletion_timestamp}" ]]; then
        return 1
    fi

    if [[ "${node}" != "${WORKER1_NODE}" ]]; then
        return 1
    fi

    if [[ -z "${pod_ip}" ]]; then
        return 1
    fi

    return 0
}

wait_clean_workload_worker1() {
    local timeout="${1:-120}"

    local start
    start="$(date +%s)"

    while true; do
        if workload_is_clean_on_worker1; then
            return 0
        fi

        if (( $(date +%s) - start >= timeout )); then
            echo
            echo "Timeout waiting for a clean workload state on ${WORKER1_NODE}"
            echo
            echo "Current workload state:"

            kubectl get pods \
              -n "${NAMESPACE}" \
              -l "${LABEL_SELECTOR}" \
              -o wide \
              || true

            return 1
        fi

        sleep 2
    done
}

get_clean_workload_name() {
    get_workload_snapshot \
      | sed '/^[[:space:]]*$/d' \
      | head -n 1 \
      | cut -d'|' -f1
}

get_clean_workload_ip() {
    get_workload_snapshot \
      | sed '/^[[:space:]]*$/d' \
      | head -n 1 \
      | cut -d'|' -f5
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

wait_scenario_c_recovery() {
    local original_pod="$1"
    local timeout="$2"

    local start
    start="$(date +%s)"

    while true; do
        local snapshot

        snapshot="$(
            get_workload_snapshot
        )"

        while IFS='|' read -r \
            pod_name \
            phase \
            deletion_timestamp \
            node \
            pod_ip
        do
            if [[ -z "${pod_name}" ]]; then
                continue
            fi

            if [[ "${pod_name}" == "${original_pod}" ]]; then
                continue
            fi

            if [[ "${phase}" != "Running" ]]; then
                continue
            fi

            if [[ -n "${deletion_timestamp}" ]]; then
                continue
            fi

            if [[ "${node}" != "${WORKER2_NODE}" ]]; then
                continue
            fi

            if [[ -z "${pod_ip}" ]]; then
                continue
            fi

            #
            # A replacement Pod is genuinely Running on Worker2.
            # Only now do we use Worker2's service path to verify
            # that service has actually been restored.
            #
            if curl \
                --silent \
                --show-error \
                --max-time 2 \
                --output /dev/null \
                --fail \
                "http://${WORKER2_IP}:${NODEPORT}"
            then
                printf '%s\n' \
                  "${pod_name}"

                return 0
            fi

        done <<< "${snapshot}"

        if (( $(date +%s) - start >= timeout )); then
            return 1
        fi

        sleep 2
    done
}

echo
echo "=========================================="
echo "Experiment run"
echo "Scenario : ${SCENARIO}"
echo "Mode     : ${MODE}"
echo "Run      : ${RUN_NUMBER}"
echo "=========================================="
echo

#
# PRE-FLIGHT
#

echo "[1/9] Clearing stale faults"

"${SCRIPT_DIR}/fault.sh" \
  clear-all \
  || true

echo "[2/9] Waiting for nodes"

wait_node_ready \
  "${WORKER1_NODE}" \
  120

wait_node_ready \
  "${WORKER2_NODE}" \
  120

#
# APPLY THE CORRECT WORKLOAD MODE
#

echo "[3/9] Applying workload mode"

if [[ "${MODE}" == "native" ]]; then
    kubectl apply \
      -f "${NATIVE_MANIFEST}"
else
    kubectl apply \
      -f "${FA_MANIFEST}"
fi

kubectl rollout status \
  deployment/baseline-web \
  -n "${NAMESPACE}" \
  --timeout=120s

#
# NORMALIZE INITIAL WORKLOAD STATE
#

echo
echo "Checking initial workload state"

if ! workload_is_clean_on_worker1; then
    echo
    echo "Workload is not in the required clean starting state."
    echo "Recreating managed Pod(s)."

    kubectl get pods \
      -n "${NAMESPACE}" \
      -l "${LABEL_SELECTOR}" \
      -o wide \
      || true

    kubectl delete pod \
      -n "${NAMESPACE}" \
      -l "${LABEL_SELECTOR}" \
      --wait=true \
      --timeout=120s \
      || true
fi

echo
echo "Waiting for exactly one clean Running Pod on ${WORKER1_NODE}"

wait_clean_workload_worker1 \
  120

ORIGINAL_POD="$(
    get_clean_workload_name
)"

ORIGINAL_POD_IP="$(
    get_clean_workload_ip
)"

echo
echo "Clean initial workload established"
echo "Original Pod    : ${ORIGINAL_POD}"
echo "Original Pod IP : ${ORIGINAL_POD_IP}"
echo "Original Node   : ${WORKER1_NODE}"

#
# VERIFY HEALTHY INITIAL STATE
#

echo
echo "[4/9] Checking healthy starting state"

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

#
# SELECT HARNESS CONFIG
#

if [[ "${SCENARIO}" == "scenario-b" ]]; then
    HARNESS_CONFIG_PATH="${SCENARIO_B_CONFIG}"
else
    HARNESS_CONFIG_PATH="${SCENARIO_C_CONFIG}"
fi

#
# START HARNESS
#

echo
echo "[5/9] Starting harness"

HARNESS_CONFIG="${HARNESS_CONFIG_PATH}" \
"${HARNESS_BINARY}" \
  > "${RUN_DIR}/harness.log" \
  2>&1 &

HARNESS_PID=$!

#
# START CONTROLLER IN FAILURE-AWARE MODE
#

if [[ "${MODE}" == "failure-aware" ]]; then
    echo "Starting Failure-Aware Controller"

    (
        cd "${REPO_ROOT}"
        "${CONTROLLER_BINARY}"
    ) \
      > "${RUN_DIR}/controller.log" \
      2>&1 &

    CONTROLLER_PID=$!

else
    echo "Native mode: Failure-Aware Controller disabled"

    printf '%s\n' \
      "Native Kubernetes experiment. Failure-Aware Controller was not started." \
      > "${RUN_DIR}/controller.log"
fi

#
# ESTABLISH PRE-FAULT OBSERVATION WINDOW
#

echo
echo "Baseline observation window: ${BASELINE_SECONDS}s"

sleep "${BASELINE_SECONDS}"

RUN_START="$(
    utc_now
)"

cat > "${RUN_DIR}/experiment-metadata.json" <<EOF
{
  "scenario": "${SCENARIO}",
  "mode": "${MODE}",
  "run_number": "${RUN_NUMBER}",
  "run_start_utc": "${RUN_START}",
  "original_pod": "${ORIGINAL_POD}",
  "original_pod_ip": "${ORIGINAL_POD_IP}",
  "original_node": "${WORKER1_NODE}",
  "worker1_ip": "${WORKER1_IP}",
  "worker2_ip": "${WORKER2_IP}",
  "nodeport": ${NODEPORT}
}
EOF

#
# INJECT FAULT
#

echo
echo "[6/9] Injecting fault"

FAULT_TIME="$(
    utc_now
)"

printf '%s\n' \
  "${FAULT_TIME}" \
  > "${RUN_DIR}/fault-time.txt"

if [[ "${SCENARIO}" == "scenario-b" ]]; then

    "${SCRIPT_DIR}/fault.sh" \
      scenario-b \
      apply

else

    "${SCRIPT_DIR}/fault.sh" \
      scenario-c \
      apply \
      "${ORIGINAL_POD_IP}"

fi

FAULT_ACTIVE="true"

#
# OBSERVATION WINDOW
#

echo
echo "[7/9] Observing experiment"

if [[ "${SCENARIO}" == "scenario-b" ]]; then

    echo
    echo "Holding Scenario B fault for ${SCENARIO_B_FAULT_SECONDS}s"

    sleep "${SCENARIO_B_FAULT_SECONDS}"

else

    echo
    echo "Waiting for genuine recovery on ${WORKER2_NODE}"
    echo "Required conditions:"
    echo "  1. Replacement Pod differs from ${ORIGINAL_POD}"
    echo "  2. Replacement Pod is Running"
    echo "  3. Replacement Pod is on ${WORKER2_NODE}"
    echo "  4. Worker2 service path returns HTTP success"

    REPLACEMENT_POD=""

    if REPLACEMENT_POD="$(
        wait_scenario_c_recovery \
          "${ORIGINAL_POD}" \
          "${SCENARIO_C_TIMEOUT_SECONDS}"
    )"
    then

        SERVICE_RESTORED_TIME="$(
            utc_now
        )"

        printf '%s\n' \
          "${REPLACEMENT_POD}" \
          > "${RUN_DIR}/replacement-pod.txt"

        printf '%s\n' \
          "${SERVICE_RESTORED_TIME}" \
          > "${RUN_DIR}/service-restored-time.txt"

        echo
        echo "Scenario C recovery confirmed"
        echo "Original Pod    : ${ORIGINAL_POD}"
        echo "Replacement Pod : ${REPLACEMENT_POD}"
        echo "Recovery Node   : ${WORKER2_NODE}"
        echo "Service         : restored"

    else

        echo
        echo "Scenario C recovery did not complete before timeout"

        printf '%s\n' \
          "TIMEOUT" \
          > "${RUN_DIR}/service-restored-time.txt"

        printf '%s\n' \
          "NOT_OBSERVED" \
          > "${RUN_DIR}/replacement-pod.txt"
    fi

fi

#
# CLEAR FAULT
#

echo
echo "[8/9] Clearing fault"

FAULT_CLEAR_TIME="$(
    utc_now
)"

printf '%s\n' \
  "${FAULT_CLEAR_TIME}" \
  > "${RUN_DIR}/fault-clear-time.txt"

"${SCRIPT_DIR}/fault.sh" \
  "${SCENARIO}" \
  clear

FAULT_ACTIVE="false"

#
# POST-FAULT OBSERVATION
#

echo
echo "Post-clear observation window: ${POST_CLEAR_SECONDS}s"

sleep "${POST_CLEAR_SECONDS}"

kubectl get pods \
  -n "${NAMESPACE}" \
  -l "${LABEL_SELECTOR}" \
  -o wide \
  > "${RUN_DIR}/pods-after.txt"

kubectl get nodes \
  -o wide \
  > "${RUN_DIR}/nodes-after.txt"

#
# STOP OBSERVERS
#

echo
echo "[9/9] Stopping observers"

if [[ -n "${HARNESS_PID}" ]]; then
    kill -INT \
      "${HARNESS_PID}" \
      2>/dev/null \
      || true

    wait \
      "${HARNESS_PID}" \
      2>/dev/null \
      || true

    HARNESS_PID=""
fi

if [[ -n "${CONTROLLER_PID}" ]]; then
    kill \
      "${CONTROLLER_PID}" \
      2>/dev/null \
      || true

    wait \
      "${CONTROLLER_PID}" \
      2>/dev/null \
      || true

    CONTROLLER_PID=""
fi

#
# COPY HARNESS RUN INTO FORMAL EXPERIMENT DIRECTORY
#

HARNESS_RUN_ROOT="${REPO_ROOT}/experiments/baseline/${SCENARIO}/runs"

LATEST_HARNESS_RUN="$(
    ls -1dt \
      "${HARNESS_RUN_ROOT}"/run-* \
      2>/dev/null \
      | head -n 1 \
      || true
)"

if [[ -n "${LATEST_HARNESS_RUN}" ]]; then
    echo
    echo "Copying harness results from:"
    echo "${LATEST_HARNESS_RUN}"

    cp -a \
      "${LATEST_HARNESS_RUN}/." \
      "${RUN_DIR}/"
else
    echo
    echo "WARNING: no harness run directory found"
fi

touch \
  "${RUN_DIR}/COMPLETE"

trap - EXIT INT TERM

echo
echo "=========================================="
echo "RUN COMPLETE"
echo "${RUN_DIR}"
echo "=========================================="