#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

source "${SCRIPT_DIR}/scenario-d-config.sh"

RUN_NUMBER="${1:-}"

if [[ -z "${RUN_NUMBER}" ]]; then
    echo "Usage:"
    echo "  $0 <run-number>"
    echo
    echo "Example:"
    echo "  $0 001"
    exit 1
fi

RUN_DIR="${RESULT_ROOT}/run-${RUN_NUMBER}"

if [[ -f "${RUN_DIR}/COMPLETE" ]]; then
    echo "Run already complete:"
    echo "${RUN_DIR}"
    exit 0
fi

mkdir -p "${RUN_DIR}"

LOG_FILE="${RUN_DIR}/scenario-d.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

cleanup() {
    echo
    echo "[CLEANUP] Restoring storage access"

    "${SCRIPT_DIR}/storage-fence.sh" unfence \
        >/dev/null 2>&1 \
        || true
}

trap cleanup EXIT

echo "=================================================="
echo "Scenario D - Stateful Storage Fencing"
echo "Run: ${RUN_NUMBER}"
echo "=================================================="

#
# --------------------------------------------------
# Markers used to verify authoritative writes.
# --------------------------------------------------
#

PRE_FENCE_MARKER="${WORKER1_NODE}-before-fence-run-${RUN_NUMBER}"

POST_FENCE_MARKER="${WORKER1_NODE}-after-fence-run-${RUN_NUMBER}"

RECOVERY_MARKER="${WORKER2_NODE}-after-recovery-run-${RUN_NUMBER}"

#
# --------------------------------------------------
# 1. Check experiment environment
# --------------------------------------------------
#

echo
echo "[1/11] Checking experiment environment"

kubectl get node "${WORKER1_NODE}" >/dev/null

kubectl get node "${WORKER2_NODE}" >/dev/null

echo "Worker nodes found"

#
# --------------------------------------------------
# 2. Clear stale storage fence
# --------------------------------------------------
#

echo
echo "[2/11] Clearing stale storage fence"

"${SCRIPT_DIR}/storage-fence.sh" unfence

#
# --------------------------------------------------
# 3. Apply Scenario D workload
# --------------------------------------------------
#

echo
echo "[3/11] Applying Scenario D workload"

kubectl apply \
    -f "${POSTGRES_STORAGE_MANIFEST}"

kubectl apply \
    -f "${POSTGRES_MANIFEST}"

kubectl rollout status \
    deployment/"${POSTGRES_DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    --timeout=120s

#
# --------------------------------------------------
# 4. Record original workload
# --------------------------------------------------
#

echo
echo "[4/11] Recording original workload"

ORIGINAL_POD="$(
    kubectl get pods \
        -n "${NAMESPACE}" \
        -l "${POSTGRES_LABEL}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}'
)"

ORIGINAL_NODE="$(
    kubectl get pod \
        -n "${NAMESPACE}" \
        "${ORIGINAL_POD}" \
        -o jsonpath='{.spec.nodeName}'
)"

echo "${ORIGINAL_POD}" \
    > "${RUN_DIR}/original-pod.txt"

echo "${ORIGINAL_NODE}" \
    > "${RUN_DIR}/original-node.txt"

kubectl get pod \
    -n "${NAMESPACE}" \
    "${ORIGINAL_POD}" \
    -o wide \
    > "${RUN_DIR}/pod-before.txt"

echo "Original Pod : ${ORIGINAL_POD}"
echo "Original Node: ${ORIGINAL_NODE}"

if [[ "${ORIGINAL_NODE}" != "${WORKER1_NODE}" ]]; then
    echo "ERROR: PostgreSQL is not running on ${WORKER1_NODE}"
    exit 1
fi

#
# --------------------------------------------------
# 5. Verify PostgreSQL readiness
# --------------------------------------------------
#

echo
echo "[5/11] Verifying PostgreSQL readiness"

kubectl exec \
    -n "${NAMESPACE}" \
    "${ORIGINAL_POD}" \
    -- pg_isready \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}"

#
# --------------------------------------------------
# 6. Create table and perform pre-fence write
# --------------------------------------------------
#

echo
echo "[6/11] Verifying pre-fence storage authority"

kubectl exec \
    -n "${NAMESPACE}" \
    "${ORIGINAL_POD}" \
    -- psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -c "
CREATE TABLE IF NOT EXISTS fence_test (
    id BIGSERIAL PRIMARY KEY,
    writer TEXT NOT NULL,
    written_at TIMESTAMPTZ DEFAULT NOW()
);"

PRE_FENCE_TIME="$(timestamp)"

echo "${PRE_FENCE_TIME}" \
    > "${RUN_DIR}/pre-fence-write-time.txt"

kubectl exec \
    -n "${NAMESPACE}" \
    "${ORIGINAL_POD}" \
    -- psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -c "
INSERT INTO fence_test(writer)
VALUES ('${PRE_FENCE_MARKER}');"

echo "Pre-fence write completed:"
echo "  ${PRE_FENCE_MARKER}"

#
# --------------------------------------------------
# 7. Apply storage fence
# --------------------------------------------------
#

echo
echo "[7/11] Applying storage fence"

FENCE_TIME="$(timestamp)"

echo "${FENCE_TIME}" \
    > "${RUN_DIR}/fence-time.txt"

"${SCRIPT_DIR}/storage-fence.sh" fence

"${SCRIPT_DIR}/storage-fence.sh" status \
    > "${RUN_DIR}/fence-status.txt"

echo "Storage fence applied"

#
# --------------------------------------------------
# 8. Test old authority and release it
# --------------------------------------------------
#

echo
echo "[8/11] Testing old storage authority"

set +e

timeout 10s \
kubectl exec \
    -n "${NAMESPACE}" \
    "${ORIGINAL_POD}" \
    -- psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -c "
INSERT INTO fence_test(writer)
VALUES ('${POST_FENCE_MARKER}');" \
    > "${RUN_DIR}/old-authority-write.txt" \
    2>&1

OLD_WRITE_RC=$?

set -e

echo "${OLD_WRITE_RC}" \
    > "${RUN_DIR}/old-authority-write-exit-code.txt"

echo "Old-authority write exit code: ${OLD_WRITE_RC}"

if [[ "${OLD_WRITE_RC}" -eq 0 ]]; then
    echo "ERROR: Worker1 successfully completed the write while fenced."
    exit 1
fi

if [[ "${OLD_WRITE_RC}" -eq 124 ]]; then
    echo "Old-authority write blocked beyond 10-second observation window."
else
    echo "Old-authority write failed with exit code ${OLD_WRITE_RC}."
fi

#
# A timeout alone does not prove permanent exclusion.
# Remove the old PostgreSQL authority before restoring
# access or allowing a new writer to become authoritative.
#

echo "Deleting old PostgreSQL Pod while Worker1 remains fenced"

kubectl delete pod \
    -n "${NAMESPACE}" \
    "${ORIGINAL_POD}" \
    --grace-period=0 \
    --force \
    --wait=false

FENCE_VERIFIED_TIME="$(timestamp)"

echo "${FENCE_VERIFIED_TIME}" \
    > "${RUN_DIR}/fence-verified-time.txt"

#
# Move the Deployment to the recovery node.
#

echo "Switching PostgreSQL placement to ${WORKER2_NODE}"

kubectl patch deployment \
    "${POSTGRES_DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    --type='json' \
    -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/nodeSelector/experiment-role",
        "value": "recovery-target"
      }
    ]'

#
# --------------------------------------------------
# 9. Wait for recovery on Worker2
# --------------------------------------------------
#

echo
echo "[9/11] Waiting for PostgreSQL recovery on ${WORKER2_NODE}"

RECOVERY_START="$(date +%s)"

REPLACEMENT_POD=""

while true
do
    REPLACEMENT_POD="$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l "${POSTGRES_LABEL}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"\n"}{end}' \
            2>/dev/null \
        | awk -F'|' \
            -v original="${ORIGINAL_POD}" \
            -v worker="${WORKER2_NODE}" \
            '$1 != original && $2 == "Running" && $3 == worker {print $1; exit}'
    )"

    if [[ -n "${REPLACEMENT_POD}" ]]; then
        break
    fi

    NOW="$(date +%s)"

    if (( NOW - RECOVERY_START > RECOVERY_TIMEOUT_SECONDS )); then
        echo "ERROR: timed out waiting for PostgreSQL recovery on ${WORKER2_NODE}"
        exit 1
    fi

    sleep 2
done

REPLACEMENT_NODE="$(
    kubectl get pod \
        -n "${NAMESPACE}" \
        "${REPLACEMENT_POD}" \
        -o jsonpath='{.spec.nodeName}'
)"

echo "Replacement Pod detected:"
echo "  Pod : ${REPLACEMENT_POD}"
echo "  Node: ${REPLACEMENT_NODE}"

echo
echo "Waiting for PostgreSQL readiness inside replacement Pod"

READY_START="$(date +%s)"

while true
do
    if kubectl exec \
        -n "${NAMESPACE}" \
        "${REPLACEMENT_POD}" \
        -- pg_isready \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DATABASE}" \
        >/dev/null 2>&1
    then
        break
    fi

    NOW="$(date +%s)"

    if (( NOW - READY_START > RECOVERY_TIMEOUT_SECONDS )); then
        echo "ERROR: PostgreSQL did not become ready on ${WORKER2_NODE}"
        exit 1
    fi

    sleep 2
done

RECOVERY_TIME="$(timestamp)"

echo "${RECOVERY_TIME}" \
    > "${RUN_DIR}/recovery-time.txt"

echo "${REPLACEMENT_POD}" \
    > "${RUN_DIR}/replacement-pod.txt"

echo "${REPLACEMENT_NODE}" \
    > "${RUN_DIR}/replacement-node.txt"

#
# --------------------------------------------------
# 10. Verify storage-authority exclusion
# --------------------------------------------------
#

echo
echo "[10/11] Verifying storage-authority exclusion"

#
# Keep the human-readable table for the experiment record.
#

kubectl exec \
    -n "${NAMESPACE}" \
    "${REPLACEMENT_POD}" \
    -- psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -c "
SELECT *
FROM fence_test
ORDER BY id;" \
    | tee "${RUN_DIR}/persistent-data-after-recovery.txt"

#
# IMPORTANT:
#
# Do not parse the formatted psql table above.
# Ask PostgreSQL directly for numeric counts using -t -A.
#

PRE_FENCE_COUNT="$(
    kubectl exec \
        -n "${NAMESPACE}" \
        "${REPLACEMENT_POD}" \
        -- psql \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DATABASE}" \
        -t \
        -A \
        -c "
SELECT COUNT(*)
FROM fence_test
WHERE writer = '${PRE_FENCE_MARKER}';" \
    | tr -d '[:space:]'
)"

POST_FENCE_COUNT="$(
    kubectl exec \
        -n "${NAMESPACE}" \
        "${REPLACEMENT_POD}" \
        -- psql \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DATABASE}" \
        -t \
        -A \
        -c "
SELECT COUNT(*)
FROM fence_test
WHERE writer = '${POST_FENCE_MARKER}';" \
    | tr -d '[:space:]'
)"

echo "Pre-fence marker count : ${PRE_FENCE_COUNT}"
echo "Post-fence marker count: ${POST_FENCE_COUNT}"

echo "${PRE_FENCE_COUNT}" \
    > "${RUN_DIR}/pre-fence-marker-count.txt"

echo "${POST_FENCE_COUNT}" \
    > "${RUN_DIR}/post-fence-marker-count.txt"

if [[ ! "${PRE_FENCE_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unable to parse pre-fence marker count."
    echo "Returned value: ${PRE_FENCE_COUNT}"
    exit 1
fi

if [[ ! "${POST_FENCE_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unable to parse post-fence marker count."
    echo "Returned value: ${POST_FENCE_COUNT}"
    exit 1
fi

if (( PRE_FENCE_COUNT < 1 )); then
    echo "ERROR: expected pre-fence row was not found."
    echo "Expected marker: ${PRE_FENCE_MARKER}"
    exit 1
fi

if (( POST_FENCE_COUNT > 0 )); then
    echo "ERROR: post-fence write was committed."
    echo "Unsafe storage-authority transition detected."
    echo "Unexpected marker: ${POST_FENCE_MARKER}"
    exit 1
fi

echo "Storage-authority exclusion verified:"
echo "  pre-fence write persisted"
echo "  post-fence Worker1 write did not commit"

#
# --------------------------------------------------
# 11. Verify Worker2 becomes the new authority
# --------------------------------------------------
#

echo
echo "[11/11] Verifying new storage authority"

kubectl exec \
    -n "${NAMESPACE}" \
    "${REPLACEMENT_POD}" \
    -- psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -c "
INSERT INTO fence_test(writer)
VALUES ('${RECOVERY_MARKER}');"

POST_RECOVERY_TIME="$(timestamp)"

echo "${POST_RECOVERY_TIME}" \
    > "${RUN_DIR}/post-recovery-write-time.txt"

RECOVERY_MARKER_COUNT="$(
    kubectl exec \
        -n "${NAMESPACE}" \
        "${REPLACEMENT_POD}" \
        -- psql \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DATABASE}" \
        -t \
        -A \
        -c "
SELECT COUNT(*)
FROM fence_test
WHERE writer = '${RECOVERY_MARKER}';" \
    | tr -d '[:space:]'
)"

echo "${RECOVERY_MARKER_COUNT}" \
    > "${RUN_DIR}/recovery-marker-count.txt"

if [[ ! "${RECOVERY_MARKER_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unable to parse recovery marker count."
    exit 1
fi

if (( RECOVERY_MARKER_COUNT < 1 )); then
    echo "ERROR: Worker2 recovery write was not persisted."
    exit 1
fi

kubectl exec \
    -n "${NAMESPACE}" \
    "${REPLACEMENT_POD}" \
    -- psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DATABASE}" \
    -c "
SELECT *
FROM fence_test
ORDER BY id;" \
    > "${RUN_DIR}/final-database-state.txt"

kubectl get pods \
    -n "${NAMESPACE}" \
    -l "${POSTGRES_LABEL}" \
    -o wide \
    > "${RUN_DIR}/pods-after.txt"

kubectl get nodes \
    -o wide \
    > "${RUN_DIR}/nodes-after.txt"

cat > "${RUN_DIR}/metadata.txt" <<EOF
scenario=scenario-d
mode=failure-aware
run=${RUN_NUMBER}
original_pod=${ORIGINAL_POD}
original_node=${ORIGINAL_NODE}
replacement_pod=${REPLACEMENT_POD}
replacement_node=${REPLACEMENT_NODE}
pre_fence_marker=${PRE_FENCE_MARKER}
post_fence_marker=${POST_FENCE_MARKER}
recovery_marker=${RECOVERY_MARKER}
fence_time=${FENCE_TIME}
fence_verified_time=${FENCE_VERIFIED_TIME}
recovery_time=${RECOVERY_TIME}
EOF

touch "${RUN_DIR}/COMPLETE"

echo
echo "=================================================="
echo "SCENARIO D COMPLETE"
echo
echo "Old authority : ${WORKER1_NODE}"
echo "New authority : ${WORKER2_NODE}"
echo "Fence         : verified"
echo "Pre-fence row : preserved"
echo "Post-fence row: absent"
echo "Recovery write: persisted"
echo
echo "${RUN_DIR}"
echo "=================================================="

trap - EXIT

cleanup