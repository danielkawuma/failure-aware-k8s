#!/usr/bin/env bash
set -euo pipefail

#
# Failure-Aware Kubernetes fencing orchestrator.
#
# Supported modes:
#
#   nfs:
#     Preserves the original Scenario D storage-fencing
#     behavior for PostgreSQL experiments.
#
#   workload:
#     Uses the independent workload-authority agent
#     through the existing remote fencing backend.
#
# Supported actions:
#
#   fence
#   status
#   unfence
#
# No database engine is hardcoded.
#

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)"

source "${SCRIPT_DIR}/scenario-d-config.sh"

ACTION="${1:-}"

case "${ACTION}" in
    fence|status|unfence)
        ;;
    *)
        echo "Usage: $0 {fence|status|unfence}" >&2
        exit 2
        ;;
esac

#
# Preserve legacy NFS mode by default.
#
FENCE_MODE="${FAILURE_AWARE_FENCE_MODE:-nfs}"

case "${FENCE_MODE}" in
    nfs|workload)
        ;;
    *)
        echo "ERROR: Unsupported fencing mode: ${FENCE_MODE}" >&2
        exit 2
        ;;
esac

#
# Remote connection configuration.
#
REMOTE_HOST="${FAILURE_AWARE_FENCE_REMOTE_HOST:-${STORAGE_SERVER_SSH}}"
REMOTE_SCRIPT="${FAILURE_AWARE_FENCE_REMOTE_SCRIPT:-${STORAGE_FENCE_REMOTE}}"

WORKER_IP="${FAILURE_AWARE_FENCE_WORKER_IP:-${WORKER1_IP}}"
NFS_PORT="${FAILURE_AWARE_FENCE_NFS_PORT:-2049}"

WORKLOAD_ID="${FAILURE_AWARE_FENCE_WORKLOAD_ID:-}"
WORKLOAD_NODE="${FAILURE_AWARE_FENCE_WORKLOAD_NODE:-}"

AUTHORITY_AGENT="${FAILURE_AWARE_AUTHORITY_AGENT:-}"

SSH_CONNECT_TIMEOUT="${FAILURE_AWARE_SSH_CONNECT_TIMEOUT:-5}"
SSH_COMMAND_TIMEOUT="${FAILURE_AWARE_SSH_COMMAND_TIMEOUT:-45}"

log() {
    printf '[FENCE ORCHESTRATOR] %s\n' "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

#
# Validate timeout parameters.
#
validate_positive_integer() {
    local value="$1"
    local name="$2"

    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        fail "${name} must be a positive integer"
    fi

    if (( value < 1 )); then
        fail "${name} must be greater than zero"
    fi
}

validate_positive_integer \
    "${SSH_CONNECT_TIMEOUT}" \
    "SSH connect timeout"

validate_positive_integer \
    "${SSH_COMMAND_TIMEOUT}" \
    "SSH command timeout"

#
# Validate SSH configuration.
#
[[ -n "${SSH_KEY:-}" ]] ||
    fail "SSH_KEY is not configured"

[[ -f "${SSH_KEY}" ]] ||
    fail "SSH private key does not exist: ${SSH_KEY}"

[[ -n "${REMOTE_HOST}" ]] ||
    fail "Remote fencing host is not configured"

[[ "${REMOTE_HOST}" =~ ^[a-zA-Z0-9._@:-]+$ ]] ||
    fail "Invalid remote fencing host"

[[ "${REMOTE_SCRIPT}" = /* ]] ||
    fail "Remote fencing script must use an absolute path"

[[ "${REMOTE_SCRIPT}" =~ ^/[a-zA-Z0-9._/-]+$ ]] ||
    fail "Invalid remote fencing script path"

#
# Validate workload mode.
#
if [[ "${FENCE_MODE}" == "workload" ]]; then

    [[ -n "${WORKLOAD_ID}" ]] ||
        fail "FAILURE_AWARE_FENCE_WORKLOAD_ID is required"

    [[ -n "${WORKLOAD_NODE}" ]] ||
        fail "FAILURE_AWARE_FENCE_WORKLOAD_NODE is required"

    [[ -n "${AUTHORITY_AGENT}" ]] ||
        fail "FAILURE_AWARE_AUTHORITY_AGENT is required"

    [[ "${WORKLOAD_ID}" =~ ^[a-zA-Z0-9._:/-]+$ ]] ||
        fail "Invalid workload identifier"

    [[ "${WORKLOAD_NODE}" =~ ^[a-zA-Z0-9._-]+$ ]] ||
        fail "Invalid workload node"

    [[ "${AUTHORITY_AGENT}" =~ ^/[a-zA-Z0-9._/-]+$ ]] ||
        fail "Invalid authority agent path"

fi

#
# Construct a safely quoted remote command.
#
# Values are passed through an explicit environment.
# They are not interpolated into arbitrary shell code.
#
printf -v REMOTE_COMMAND \
    'sudo -n env FAILURE_AWARE_FENCE_MODE=%q FAILURE_AWARE_FENCE_WORKER_IP=%q FAILURE_AWARE_FENCE_NFS_PORT=%q FAILURE_AWARE_FENCE_WORKLOAD_ID=%q FAILURE_AWARE_FENCE_WORKLOAD_NODE=%q FAILURE_AWARE_AUTHORITY_AGENT=%q %q %q' \
    "${FENCE_MODE}" \
    "${WORKER_IP}" \
    "${NFS_PORT}" \
    "${WORKLOAD_ID}" \
    "${WORKLOAD_NODE}" \
    "${AUTHORITY_AGENT}" \
    "${REMOTE_SCRIPT}" \
    "${ACTION}"

log "action=${ACTION}"
log "mode=${FENCE_MODE}"
log "remote=${REMOTE_HOST}"

if [[ "${FENCE_MODE}" == "workload" ]]; then
    log "workload=${WORKLOAD_ID}"
    log "node=${WORKLOAD_NODE}"
fi

#
# Execute the remote fencing operation.
#
# A timeout or SSH failure must never be interpreted
# as proof of successful fencing.
#
if timeout \
    --signal=TERM \
    --kill-after=5s \
    "${SSH_COMMAND_TIMEOUT}s" \
    ssh \
        -i "${SSH_KEY}" \
        -o BatchMode=yes \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "${REMOTE_HOST}" \
        "${REMOTE_COMMAND}"
then
    log "action=${ACTION} completed successfully"
else
    rc=$?

    log "action=${ACTION} failed with exit code ${rc}"

    if [[ "${rc}" -eq 124 || "${rc}" -eq 137 ]]; then
        log "Remote operation timed out; fencing outcome is unverified"
    fi

    exit "${rc}"
fi

#
# A successful fence command must also pass
# an independent status verification.
#
# This check validates the backend's reported
# state; it does not independently establish
# storage-level exclusion.
#
if [[ "${ACTION}" == "fence" ]]; then

    log "Verifying reported fencing state"

    printf -v STATUS_COMMAND \
        'sudo -n env FAILURE_AWARE_FENCE_MODE=%q FAILURE_AWARE_FENCE_WORKER_IP=%q FAILURE_AWARE_FENCE_NFS_PORT=%q FAILURE_AWARE_FENCE_WORKLOAD_ID=%q FAILURE_AWARE_FENCE_WORKLOAD_NODE=%q FAILURE_AWARE_AUTHORITY_AGENT=%q %q status' \
        "${FENCE_MODE}" \
        "${WORKER_IP}" \
        "${NFS_PORT}" \
        "${WORKLOAD_ID}" \
        "${WORKLOAD_NODE}" \
        "${AUTHORITY_AGENT}" \
        "${REMOTE_SCRIPT}"

    if timeout \
        --signal=TERM \
        --kill-after=5s \
        "${SSH_COMMAND_TIMEOUT}s" \
        ssh \
            -i "${SSH_KEY}" \
            -o BatchMode=yes \
            -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=2 \
            "${REMOTE_HOST}" \
            "${STATUS_COMMAND}"
    then
        log "Fencing status verification passed"
    else
        log "ERROR: Fencing status verification failed"
        exit 1
    fi

fi

exit 0