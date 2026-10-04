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

RUN_NUMBER="${1:-}"

if [[ -z "${RUN_NUMBER}" ]]; then
    echo "Usage: $0 <run-number>"
    exit 1
fi

RUN_DIR="${RESULT_ROOT}/run-${RUN_NUMBER}"
mkdir -p "${RUN_DIR}"

FENCE_ACTIVE="false"
OLD_AUTHORITY_STOPPED="false"
ORIGINAL_POD=""
ORIGINAL_CONTAINER_ID=""
RECOVERY_POD=""

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
}

psql_exec() {
    local pod_name="$1"
    local sql_statement="$2"

    kubectl exec \
      -n "${NAMESPACE}" \
      "${pod_name}" \
      -- \
      psql \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DATABASE}" \
        -v ON_ERROR_STOP=1 \
        -tAc "${sql_statement}"
}

get_marker_count() {
    local pod_name="$1"
    local marker="$2"

    psql_exec \
      "${pod_name}" \
      "
      SELECT COUNT(*)
      FROM scenario_d_fence_test
      WHERE marker = '${marker}';
      " \
      | tr -d '[:space:]'
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

latest_postgres_pod() {
    kubectl get pods \
      -n "${NAMESPACE}" \
      -l "${POSTGRES_LABEL}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' \
      2>/dev/null || true
}

worker1_original_container_ids() {
    if [[ -z "${ORIGINAL_POD}" ]]; then
        return 0
    fi

    ssh \
      -i "${SSH_KEY}" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      "${WORKER1_SSH}" \
      "sudo k3s crictl ps \
        --label io.kubernetes.pod.name=${ORIGINAL_POD} \
        -q 2>/dev/null || true"
}

worker1_postgres_containers() {
    ssh \
      -i "${SSH_KEY}" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      "${WORKER1_SSH}" \
      "sudo k3s crictl ps 2>/dev/null \
        | grep '${POSTGRES_DEPLOYMENT}' || true"
}

wait_for_postgres() {
    local pod_name="$1"
    local timeout_seconds="$2"
    local elapsed=0

    while (( elapsed < timeout_seconds )); do
        if ! kubectl get pod \
          "${pod_name}" \
          -n "${NAMESPACE}" \
          >/dev/null 2>&1
        then
            return 1
        fi

        if kubectl exec \
          -n "${NAMESPACE}" \
          "${pod_name}" \
          -- \
          pg_isready \
            -U "${POSTGRES_USER}" \
            -d "${POSTGRES_DATABASE}" \
          >/dev/null 2>&1
        then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

cleanup() {
    local exit_code=$?

    echo
    echo "[CLEANUP] Checking storage-fence state"

    if [[ "${FENCE_ACTIVE}" == "true" ]]; then
        if [[ "${OLD_AUTHORITY_STOPPED}" == "true" ]]; then
            echo "Old authority was stopped before fencing."
            echo "Restoring Worker1 storage connectivity."

            "${SCRIPT_DIR}/storage-fence.sh" unfence || true
            FENCE_ACTIVE="false"
        else
            echo "WARNING: old authority has not been proven stopped."
            echo "The storage fence is being left active for safety."
            echo
            echo "After confirming PostgreSQL is stopped on Worker1:"
            echo "  ${SCRIPT_DIR}/storage-fence.sh unfence"
        fi
    fi

    exit "${exit_code}"
}

trap cleanup EXIT

echo "=================================================="
echo "Scenario D - Stateful Storage Fencing"
echo "Run: ${RUN_NUMBER}"
echo "=================================================="

echo
echo "[1/12] Checking experiment environment"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl get node "${WORKER1_NODE}" >/dev/null
kubectl get node "${WORKER2_NODE}" >/dev/null

ssh \
  -i "${SSH_KEY}" \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  "${WORKER1_SSH}" \
  "sudo k3s crictl version >/dev/null"

echo "Worker nodes and Worker1 runtime are accessible"

echo
echo "[2/12] Clearing stale storage fence"

"${SCRIPT_DIR}/storage-fence.sh" unfence
FENCE_ACTIVE="false"

echo
echo "[3/12] Applying Scenario D workload"

kubectl apply \
  -f "${POSTGRES_STORAGE_MANIFEST}"

kubectl apply \
  -f "${POSTGRES_MANIFEST}"

kubectl patch deployment \
  "${POSTGRES_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --type=json \
  -p="[
        {
          \"op\": \"replace\",
          \"path\": \"/spec/template/spec/nodeSelector\",
          \"value\": {
            \"kubernetes.io/hostname\": \"${WORKER1_NODE}\"
          }
        }
      ]"

kubectl rollout status \
  deployment/"${POSTGRES_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --timeout="${RECOVERY_TIMEOUT_SECONDS}s"

echo
echo "[4/12] Locating the original PostgreSQL workload"

pod_deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))

while (( SECONDS < pod_deadline )); do
    ORIGINAL_POD="$(latest_worker1_running_pod)"

    if [[ -n "${ORIGINAL_POD}" ]]; then
        break
    fi

    sleep 2
done

if [[ -z "${ORIGINAL_POD}" ]]; then
    echo "ERROR: no running PostgreSQL Pod was found on ${WORKER1_NODE}."
    exit 1
fi

ORIGINAL_NODE="$(
    kubectl get pod \
      "${ORIGINAL_POD}" \
      -n "${NAMESPACE}" \
      -o jsonpath='{.spec.nodeName}'
)"

echo "Initial Pod : ${ORIGINAL_POD}"
echo "Initial Node: ${ORIGINAL_NODE}"

echo
echo "[5/12] Waiting for initial PostgreSQL readiness"

INITIAL_READY="false"
readiness_deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))

while (( SECONDS < readiness_deadline )); do
    CURRENT_INITIAL_POD="$(latest_worker1_running_pod)"

    if [[ -n "${CURRENT_INITIAL_POD}" ]]; then
        ORIGINAL_POD="${CURRENT_INITIAL_POD}"

        if kubectl exec \
          -n "${NAMESPACE}" \
          "${ORIGINAL_POD}" \
          -- \
          pg_isready \
            -U "${POSTGRES_USER}" \
            -d "${POSTGRES_DATABASE}" \
          >/dev/null 2>&1
        then
            INITIAL_READY="true"
            break
        fi
    fi

    sleep 2
done

if [[ "${INITIAL_READY}" != "true" ]]; then
    echo "ERROR: initial PostgreSQL instance did not become ready."

    DIAGNOSTIC_POD="$(latest_postgres_pod)"

    if [[ -n "${DIAGNOSTIC_POD}" ]]; then
        kubectl describe pod \
          "${DIAGNOSTIC_POD}" \
          -n "${NAMESPACE}" \
          > "${RUN_DIR}/initial-pod-describe.txt" \
          2>&1 || true

        kubectl logs \
          "${DIAGNOSTIC_POD}" \
          -n "${NAMESPACE}" \
          > "${RUN_DIR}/initial-postgres.log" \
          2>&1 || true
    fi

    exit 1
fi

ORIGINAL_NODE="$(
    kubectl get pod \
      "${ORIGINAL_POD}" \
      -n "${NAMESPACE}" \
      -o jsonpath='{.spec.nodeName}'
)"

if [[ "${ORIGINAL_NODE}" != "${WORKER1_NODE}" ]]; then
    echo "ERROR: PostgreSQL is not running on ${WORKER1_NODE}."
    echo "Observed node: ${ORIGINAL_NODE}"
    exit 1
fi

printf '%s\n' "${ORIGINAL_POD}" \
  > "${RUN_DIR}/original-pod.txt"

printf '%s\n' "${ORIGINAL_NODE}" \
  > "${RUN_DIR}/original-node.txt"

echo "Initial PostgreSQL instance is ready"
echo "Authoritative Pod : ${ORIGINAL_POD}"
echo "Authoritative Node: ${ORIGINAL_NODE}"

echo
echo "[6/12] Verifying pre-fence storage authority"

PRE_FENCE_MARKER="k3s-worker1-before-fence-run-${RUN_NUMBER}"
POST_FENCE_MARKER="k3s-worker1-after-fence-run-${RUN_NUMBER}"
RECOVERY_MARKER="k3s-worker2-recovery-run-${RUN_NUMBER}"

psql_exec \
  "${ORIGINAL_POD}" \
  "
  CREATE TABLE IF NOT EXISTS scenario_d_fence_test (
      id BIGSERIAL PRIMARY KEY,
      marker TEXT UNIQUE NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );

  INSERT INTO scenario_d_fence_test(marker)
  VALUES ('${PRE_FENCE_MARKER}')
  ON CONFLICT (marker) DO NOTHING;
  "

PRE_FENCE_COUNT="$(
    get_marker_count \
      "${ORIGINAL_POD}" \
      "${PRE_FENCE_MARKER}"
)"

printf '%s\n' "${PRE_FENCE_COUNT}" \
  > "${RUN_DIR}/pre-fence-marker-count.txt"

if [[ "${PRE_FENCE_COUNT}" != "1" ]]; then
    echo "ERROR: pre-fence marker was not committed."
    exit 1
fi

echo "Pre-fence write completed:"
echo "  ${PRE_FENCE_MARKER}"

echo
echo "[7/12] Quiescing the old authority before NFS fencing"

printf '%s\n' "$(utc_now)" \
  > "${RUN_DIR}/old-authority-stop-start-time.txt"

ORIGINAL_CONTAINER_ID="$(
    worker1_original_container_ids \
      | head -n 1 \
      | tr -d '[:space:]'
)"

if [[ -n "${ORIGINAL_CONTAINER_ID}" ]]; then
    printf '%s\n' "${ORIGINAL_CONTAINER_ID}" \
      > "${RUN_DIR}/original-container-id.txt"
fi

echo "Scaling PostgreSQL to zero while NFS remains available"

kubectl scale deployment \
  "${POSTGRES_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --replicas=0

if [[ -n "${ORIGINAL_CONTAINER_ID}" ]]; then
    echo "Stopping original PostgreSQL container:"
    echo "  ${ORIGINAL_CONTAINER_ID}"

    ssh \
      -i "${SSH_KEY}" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      "${WORKER1_SSH}" \
      "
      sudo timeout \
        ${RUNTIME_STOP_COMMAND_TIMEOUT_SECONDS} \
        k3s crictl stop \
        ${ORIGINAL_CONTAINER_ID}
      " || true
fi

echo "Waiting for the original PostgreSQL container to stop"

stop_deadline=$((SECONDS + OLD_AUTHORITY_STOP_TIMEOUT_SECONDS))

while (( SECONDS < stop_deadline )); do
    active_ids="$(
        worker1_original_container_ids \
          | tr -d '[:space:]'
    )"

    if [[ -z "${active_ids}" ]]; then
        OLD_AUTHORITY_STOPPED="true"
        break
    fi

    sleep 2
done

if [[ "${OLD_AUTHORITY_STOPPED}" != "true" ]]; then
    echo "ERROR: original PostgreSQL container remains active."
    echo "The NFS fence has not yet been applied because storage"
    echo "must remain available while PostgreSQL shuts down."

    worker1_postgres_containers \
      > "${RUN_DIR}/old-containers-stop-failure.txt"

    exit 1
fi

kubectl delete pod \
  "${ORIGINAL_POD}" \
  -n "${NAMESPACE}" \
  --ignore-not-found=true \
  --wait=false

printf '%s\n' "$(utc_now)" \
  > "${RUN_DIR}/old-authority-stopped-time.txt"

worker1_postgres_containers \
  > "${RUN_DIR}/old-containers-after-stop.txt"

echo "Old PostgreSQL authority has stopped"

echo
echo "[8/12] Applying the NFS storage fence"

printf '%s\n' "$(utc_now)" \
  > "${RUN_DIR}/fence-time.txt"

"${SCRIPT_DIR}/storage-fence.sh" fence
FENCE_ACTIVE="true"

sleep 3

echo "Verifying that Worker1 cannot reach the NFS service"

if ssh \
    -i "${SSH_KEY}" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "${WORKER1_SSH}" \
    "
    timeout 5 bash -c \
      '</dev/tcp/${STORAGE_SERVER_IP}/2049'
    " \
    >/dev/null 2>&1
then
    echo "ERROR: Worker1 can still reach NFS TCP port 2049."
    exit 1
fi

printf '%s\n' "blocked" \
  > "${RUN_DIR}/worker1-nfs-access.txt"

echo "Worker1 has been excluded from NFS storage"

echo
echo "[9/12] Releasing recovery on Worker2"

kubectl patch deployment \
  "${POSTGRES_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --type=json \
  -p="[
        {
          \"op\": \"replace\",
          \"path\": \"/spec/template/spec/nodeSelector\",
          \"value\": {
            \"kubernetes.io/hostname\": \"${WORKER2_NODE}\"
          }
        }
      ]"

printf '%s\n' "$(utc_now)" \
  > "${RUN_DIR}/recovery-release-time.txt"

kubectl scale deployment \
  "${POSTGRES_DEPLOYMENT}" \
  -n "${NAMESPACE}" \
  --replicas=1

echo
echo "[10/12] Waiting for PostgreSQL recovery on Worker2"

recovery_deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))
RECOVERY_POD=""

while (( SECONDS < recovery_deadline )); do
    RECOVERY_POD="$(
        kubectl get pods \
          -n "${NAMESPACE}" \
          -l "${POSTGRES_LABEL}" \
          --field-selector="spec.nodeName=${WORKER2_NODE},status.phase=Running" \
          --sort-by=.metadata.creationTimestamp \
          -o jsonpath='{.items[-1].metadata.name}' \
          2>/dev/null || true
    )"

    if [[ -n "${RECOVERY_POD}" ]] &&
       wait_for_postgres "${RECOVERY_POD}" 10
    then
        break
    fi

    RECOVERY_POD=""
    sleep 2
done

if [[ -z "${RECOVERY_POD}" ]]; then
    echo "ERROR: PostgreSQL did not recover on ${WORKER2_NODE}."

    kubectl get pods \
      -n "${NAMESPACE}" \
      -l "${POSTGRES_LABEL}" \
      -o wide \
      > "${RUN_DIR}/recovery-timeout-pods.txt" \
      2>&1 || true

    DIAGNOSTIC_POD="$(latest_postgres_pod)"

    if [[ -n "${DIAGNOSTIC_POD}" ]]; then
        kubectl describe pod \
          "${DIAGNOSTIC_POD}" \
          -n "${NAMESPACE}" \
          > "${RUN_DIR}/recovery-pod-describe.txt" \
          2>&1 || true

        kubectl logs \
          "${DIAGNOSTIC_POD}" \
          -n "${NAMESPACE}" \
          > "${RUN_DIR}/recovery-postgres.log" \
          2>&1 || true
    fi

    exit 1
fi

printf '%s\n' "$(utc_now)" \
  > "${RUN_DIR}/service-restored-time.txt"

printf '%s\n' "${RECOVERY_POD}" \
  > "${RUN_DIR}/recovery-pod.txt"

printf '%s\n' "${WORKER2_NODE}" \
  > "${RUN_DIR}/recovery-node.txt"

echo "Recovery Pod : ${RECOVERY_POD}"
echo "Recovery Node: ${WORKER2_NODE}"

echo
echo "[11/12] Verifying data preservation and single-writer recovery"

PRE_FENCE_COUNT="$(
    get_marker_count \
      "${RECOVERY_POD}" \
      "${PRE_FENCE_MARKER}"
)"

POST_FENCE_COUNT="$(
    get_marker_count \
      "${RECOVERY_POD}" \
      "${POST_FENCE_MARKER}"
)"

printf '%s\n' "${PRE_FENCE_COUNT}" \
  > "${RUN_DIR}/pre-fence-marker-count.txt"

printf '%s\n' "${POST_FENCE_COUNT}" \
  > "${RUN_DIR}/post-fence-marker-count.txt"

if [[ "${PRE_FENCE_COUNT}" != "1" ]]; then
    echo "ERROR: committed pre-fence data was not preserved."
    exit 1
fi

if [[ "${POST_FENCE_COUNT}" != "0" ]]; then
    echo "ERROR: an unauthorized post-fence Worker1 write exists."
    exit 1
fi

psql_exec \
  "${RECOVERY_POD}" \
  "
  INSERT INTO scenario_d_fence_test(marker)
  VALUES ('${RECOVERY_MARKER}')
  ON CONFLICT (marker) DO NOTHING;
  "

RECOVERY_COUNT="$(
    get_marker_count \
      "${RECOVERY_POD}" \
      "${RECOVERY_MARKER}"
)"

printf '%s\n' "${RECOVERY_COUNT}" \
  > "${RUN_DIR}/recovery-marker-count.txt"

if [[ "${RECOVERY_COUNT}" != "1" ]]; then
    echo "ERROR: Worker2 recovery write was not committed."
    exit 1
fi

echo "Pre-fence data preserved"
echo "No post-fence Worker1 write observed"
echo "Worker2 is the new active writer"

echo
echo "[12/12] Verifying safe unfencing"

worker1_postgres_containers \
  > "${RUN_DIR}/old-containers-before-unfence.txt"

if [[ -s "${RUN_DIR}/old-containers-before-unfence.txt" ]]; then
    echo "ERROR: an active PostgreSQL container exists on Worker1."
    echo "The NFS fence will remain active."
    OLD_AUTHORITY_STOPPED="false"
    exit 1
fi

"${SCRIPT_DIR}/storage-fence.sh" unfence
FENCE_ACTIVE="false"

sleep "${POST_UNFENCE_SECONDS}"

worker1_postgres_containers \
  > "${RUN_DIR}/old-containers-after-unfence.txt"

if [[ -s "${RUN_DIR}/old-containers-after-unfence.txt" ]]; then
    echo "ERROR: PostgreSQL restarted on Worker1 after unfencing."
    exit 1
fi

POST_UNFENCE_COUNT="$(
    get_marker_count \
      "${RECOVERY_POD}" \
      "${POST_FENCE_MARKER}"
)"

printf '%s\n' "${POST_UNFENCE_COUNT}" \
  > "${RUN_DIR}/post-unfence-marker-count.txt"

if [[ "${POST_UNFENCE_COUNT}" != "0" ]]; then
    echo "ERROR: an old-authority write appeared after unfencing."
    exit 1
fi

sleep "${POST_RECOVERY_SECONDS}"

cat > "${RUN_DIR}/experiment-metadata.json" <<EOF
{
  "scenario": "scenario-d",
  "run_number": "${RUN_NUMBER}",
  "original_pod": "${ORIGINAL_POD}",
  "original_node": "${WORKER1_NODE}",
  "recovery_pod": "${RECOVERY_POD}",
  "recovery_node": "${WORKER2_NODE}",
  "fencing_mechanism": "ordered-runtime-stop-then-nfs-denial",
  "old_authority_stopped_before_fence": true,
  "worker1_nfs_access_blocked_before_recovery": true,
  "pre_fence_marker_preserved": true,
  "post_fence_worker1_marker_absent": true,
  "worker2_recovery_write_committed": true,
  "post_unfence_delayed_write_absent": true
}
EOF

touch "${RUN_DIR}/COMPLETE"

echo
echo "=================================================="
echo "Scenario D completed successfully"
echo "Results: ${RUN_DIR}"
echo "=================================================="

trap - EXIT
exit 0