#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

REPO_ROOT="$(
    cd "${SCRIPT_DIR}/.."
    pwd
)"

source "${SCRIPT_DIR}/scenario-d-config.sh"

START_RUN="${1:-201}"
RUN_COUNT="${2:-30}"

WORKER2_SSH="${WORKER2_SSH:-ubuntu@${WORKER2_IP}}"

CAMPAIGN_TIMESTAMP="$(
    date -u +"%Y%m%dT%H%M%SZ"
)"

CAMPAIGN_LOG="${REPO_ROOT}/analysis/results/scenario-d-campaign-${CAMPAIGN_TIMESTAMP}.log"
CAMPAIGN_SUMMARY="${REPO_ROOT}/analysis/results/scenario-d-campaign-${CAMPAIGN_TIMESTAMP}.csv"

mkdir -p "${REPO_ROOT}/analysis/results"

if ! [[ "${START_RUN}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: starting run number must be an integer."
    exit 1
fi

if ! [[ "${RUN_COUNT}" =~ ^[0-9]+$ ]] ||
   (( RUN_COUNT < 1 ))
then
    echo "ERROR: run count must be a positive integer."
    exit 1
fi

END_RUN=$((START_RUN + RUN_COUNT - 1))

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
}

latest_worker1_running_pod() {
    kubectl get pods \
      -n "${NAMESPACE}" \
      -l "${POSTGRES_LABEL}" \
      --field-selector="spec.nodeName=${WORKER1_NODE},status.phase=Running" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' \
      2>/dev/null || true
}

remote_postgres_container_ids() {
    local ssh_target="$1"

    ssh \
      -i "${SSH_KEY}" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      "${ssh_target}" \
      "
      sudo k3s crictl ps 2>/dev/null \
        | awk '/${POSTGRES_DEPLOYMENT}/ {print \$1}'
      " || true
}

stop_remote_postgres_containers() {
    local ssh_target="$1"
    local node_name="$2"
    local container_ids=""

    container_ids="$(
        remote_postgres_container_ids "${ssh_target}"
    )"

    if [[ -z "${container_ids}" ]]; then
        echo "No active PostgreSQL container found on ${node_name}"
        return 0
    fi

    echo "Stopping PostgreSQL containers on ${node_name}"

    while IFS= read -r container_id; do
        if [[ -z "${container_id}" ]]; then
            continue
        fi

        echo "Stopping container ${container_id} on ${node_name}"

        ssh \
          -i "${SSH_KEY}" \
          -o BatchMode=yes \
          -o ConnectTimeout=10 \
          "${ssh_target}" \
          "
          sudo timeout \
            ${RUNTIME_STOP_COMMAND_TIMEOUT_SECONDS} \
            k3s crictl stop \
            ${container_id}
          " || true
    done <<< "${container_ids}"
}

wait_for_no_kubernetes_postgres_pods() {
    local deadline=$((SECONDS + OLD_AUTHORITY_STOP_TIMEOUT_SECONDS))

    while (( SECONDS < deadline )); do
        remaining_pods="$(
            kubectl get pods \
              -n "${NAMESPACE}" \
              -l "${POSTGRES_LABEL}" \
              -o name \
              2>/dev/null || true
        )"

        if [[ -z "${remaining_pods}" ]]; then
            return 0
        fi

        sleep 2
    done

    return 1
}

wait_for_no_runtime_postgres_containers() {
    local ssh_target="$1"
    local deadline=$((SECONDS + OLD_AUTHORITY_STOP_TIMEOUT_SECONDS))

    while (( SECONDS < deadline )); do
        active_ids="$(
            remote_postgres_container_ids "${ssh_target}" \
              | tr -d '[:space:]'
        )"

        if [[ -z "${active_ids}" ]]; then
            return 0
        fi

        sleep 2
    done

    return 1
}

wait_for_worker1_postgres_ready() {
    local deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))
    local pod_name=""

    while (( SECONDS < deadline )); do
        pod_name="$(latest_worker1_running_pod)"

        if [[ -n "${pod_name}" ]]; then
            if kubectl exec \
              -n "${NAMESPACE}" \
              "${pod_name}" \
              -- \
              pg_isready \
                -U "${POSTGRES_USER}" \
                -d "${POSTGRES_DATABASE}" \
              >/dev/null 2>&1
            then
                printf '%s\n' "${pod_name}"
                return 0
            fi
        fi

        sleep 2
    done

    return 1
}

prepare_worker1_authority() {
    local baseline_pod=""

    echo
    echo "--------------------------------------------------"
    echo "Preparing the controlled starting state"
    echo "--------------------------------------------------"

    echo "Scaling the PostgreSQL Deployment to zero"

    if kubectl get deployment \
      "${POSTGRES_DEPLOYMENT}" \
      -n "${NAMESPACE}" \
      >/dev/null 2>&1
    then
        kubectl scale deployment \
          "${POSTGRES_DEPLOYMENT}" \
          -n "${NAMESPACE}" \
          --replicas=0
    else
        echo "Deployment does not exist; applying manifests"

        kubectl apply \
          -f "${POSTGRES_STORAGE_MANIFEST}"

        kubectl apply \
          -f "${POSTGRES_MANIFEST}"

        kubectl scale deployment \
          "${POSTGRES_DEPLOYMENT}" \
          -n "${NAMESPACE}" \
          --replicas=0
    fi

    echo "Waiting for Kubernetes PostgreSQL Pods to terminate"

    if ! wait_for_no_kubernetes_postgres_pods; then
        echo "Kubernetes Pods did not terminate before the timeout."
        echo "Applying explicit Pod deletion."

        kubectl delete pods \
          -n "${NAMESPACE}" \
          -l "${POSTGRES_LABEL}" \
          --ignore-not-found=true \
          --wait=false
    fi

    echo "Restoring Worker1 NFS access before runtime shutdown"

    "${SCRIPT_DIR}/storage-fence.sh" unfence

    echo "Checking Worker2 for an old recovery authority"

    stop_remote_postgres_containers \
      "${WORKER2_SSH}" \
      "${WORKER2_NODE}"

    if ! wait_for_no_runtime_postgres_containers \
      "${WORKER2_SSH}"
    then
        echo "ERROR: PostgreSQL remains active on ${WORKER2_NODE}."
        echo "The next experiment cannot safely start."
        return 1
    fi

    echo "Checking Worker1 for a stale PostgreSQL authority"

    stop_remote_postgres_containers \
      "${WORKER1_SSH}" \
      "${WORKER1_NODE}"

    if ! wait_for_no_runtime_postgres_containers \
      "${WORKER1_SSH}"
    then
        echo "ERROR: PostgreSQL remains active on ${WORKER1_NODE}."
        echo "The next experiment cannot safely start."
        return 1
    fi

    echo "No active PostgreSQL writer remains"

    echo "Configuring Recreate strategy and Worker1 placement"

    kubectl patch deployment \
      "${POSTGRES_DEPLOYMENT}" \
      -n "${NAMESPACE}" \
      --type=json \
      -p="[
            {
              \"op\": \"replace\",
              \"path\": \"/spec/replicas\",
              \"value\": 0
            },
            {
              \"op\": \"replace\",
              \"path\": \"/spec/strategy\",
              \"value\": {
                \"type\": \"Recreate\"
              }
            },
            {
              \"op\": \"replace\",
              \"path\": \"/spec/template/spec/nodeSelector\",
              \"value\": {
                \"kubernetes.io/hostname\": \"${WORKER1_NODE}\"
              }
            }
          ]"

    echo "Starting PostgreSQL on Worker1"

    kubectl scale deployment \
      "${POSTGRES_DEPLOYMENT}" \
      -n "${NAMESPACE}" \
      --replicas=1

    kubectl rollout status \
      deployment/"${POSTGRES_DEPLOYMENT}" \
      -n "${NAMESPACE}" \
      --timeout="${RECOVERY_TIMEOUT_SECONDS}s"

    if ! baseline_pod="$(
        wait_for_worker1_postgres_ready
    )"
    then
        echo "ERROR: PostgreSQL did not become ready on ${WORKER1_NODE}."

        kubectl get pods \
          -n "${NAMESPACE}" \
          -l "${POSTGRES_LABEL}" \
          -o wide

        return 1
    fi

    echo "Controlled starting state established"
    echo "Initial authority Pod : ${baseline_pod}"
    echo "Initial authority Node: ${WORKER1_NODE}"
}

echo "==================================================" | tee -a "${CAMPAIGN_LOG}"
echo "Scenario D Campaign" | tee -a "${CAMPAIGN_LOG}"
echo "Runs: ${START_RUN}-${END_RUN}" | tee -a "${CAMPAIGN_LOG}"
echo "Execution mode: sequential" | tee -a "${CAMPAIGN_LOG}"
echo "Started: $(utc_now)" | tee -a "${CAMPAIGN_LOG}"
echo "==================================================" | tee -a "${CAMPAIGN_LOG}"

printf '%s\n' \
  "run_number,status,start_utc,end_utc,elapsed_seconds,result_directory" \
  > "${CAMPAIGN_SUMMARY}"

echo "Checking that campaign result directories are unused"

for ((run_number = START_RUN; run_number <= END_RUN; run_number++)); do
    run_directory="${RESULT_ROOT}/run-${run_number}"

    if [[ -e "${run_directory}" ]]; then
        echo "ERROR: result directory already exists:"
        echo "  ${run_directory}"
        echo
        echo "Use a different starting run number."
        exit 1
    fi
done

completed_runs=0

for ((run_number = START_RUN; run_number <= END_RUN; run_number++)); do
    run_directory="${RESULT_ROOT}/run-${run_number}"
    run_log="${REPO_ROOT}/analysis/results/scenario-d-run-${run_number}.log"

    echo | tee -a "${CAMPAIGN_LOG}"
    echo "==================================================" | tee -a "${CAMPAIGN_LOG}"
    echo "Preparing Scenario D run ${run_number}" | tee -a "${CAMPAIGN_LOG}"
    echo "==================================================" | tee -a "${CAMPAIGN_LOG}"

    reset_start="$(
        date +%s
    )"

    if ! prepare_worker1_authority \
      2>&1 | tee -a "${CAMPAIGN_LOG}"
    then
        reset_end="$(
            date +%s
        )"

        printf '%s,%s,%s,%s,%s,%s\n' \
          "${run_number}" \
          "reset-failed" \
          "$(utc_now)" \
          "$(utc_now)" \
          "$((reset_end - reset_start))" \
          "${run_directory}" \
          >> "${CAMPAIGN_SUMMARY}"

        echo "ERROR: safe reset failed before run ${run_number}."
        echo "Campaign stopped."
        exit 1
    fi

    run_start_utc="$(utc_now)"
    run_start_epoch="$(
        date +%s
    )"

    echo | tee -a "${CAMPAIGN_LOG}"
    echo "Starting measured run ${run_number}" | tee -a "${CAMPAIGN_LOG}"

    if "${SCRIPT_DIR}/run-scenario-d.sh" \
        "${run_number}" \
        2>&1 | tee "${run_log}" | tee -a "${CAMPAIGN_LOG}"
    then
        run_end_utc="$(utc_now)"
        run_end_epoch="$(
            date +%s
        )"

        elapsed_seconds=$((run_end_epoch - run_start_epoch))

        if [[ ! -f "${run_directory}/COMPLETE" ]]; then
            echo "ERROR: run ${run_number} returned successfully"
            echo "but did not create its COMPLETE marker."

            printf '%s,%s,%s,%s,%s,%s\n' \
              "${run_number}" \
              "missing-complete-marker" \
              "${run_start_utc}" \
              "${run_end_utc}" \
              "${elapsed_seconds}" \
              "${run_directory}" \
              >> "${CAMPAIGN_SUMMARY}"

            exit 1
        fi

        completed_runs=$((completed_runs + 1))

        printf '%s,%s,%s,%s,%s,%s\n' \
          "${run_number}" \
          "completed" \
          "${run_start_utc}" \
          "${run_end_utc}" \
          "${elapsed_seconds}" \
          "${run_directory}" \
          >> "${CAMPAIGN_SUMMARY}"

        echo "Run ${run_number} completed in ${elapsed_seconds} seconds" \
          | tee -a "${CAMPAIGN_LOG}"
    else
        run_end_utc="$(utc_now)"
        run_end_epoch="$(
            date +%s
        )"

        elapsed_seconds=$((run_end_epoch - run_start_epoch))

        printf '%s,%s,%s,%s,%s,%s\n' \
          "${run_number}" \
          "failed" \
          "${run_start_utc}" \
          "${run_end_utc}" \
          "${elapsed_seconds}" \
          "${run_directory}" \
          >> "${CAMPAIGN_SUMMARY}"

        echo "ERROR: Scenario D run ${run_number} failed." \
          | tee -a "${CAMPAIGN_LOG}"

        echo "Campaign stopped after ${completed_runs} completed runs." \
          | tee -a "${CAMPAIGN_LOG}"

        exit 1
    fi
done

echo | tee -a "${CAMPAIGN_LOG}"
echo "==================================================" | tee -a "${CAMPAIGN_LOG}"
echo "Scenario D campaign completed successfully" | tee -a "${CAMPAIGN_LOG}"
echo "Completed runs: ${completed_runs}/${RUN_COUNT}" | tee -a "${CAMPAIGN_LOG}"
echo "Finished: $(utc_now)" | tee -a "${CAMPAIGN_LOG}"
echo "Campaign log: ${CAMPAIGN_LOG}" | tee -a "${CAMPAIGN_LOG}"
echo "Campaign summary: ${CAMPAIGN_SUMMARY}" | tee -a "${CAMPAIGN_LOG}"
echo "==================================================" | tee -a "${CAMPAIGN_LOG}"