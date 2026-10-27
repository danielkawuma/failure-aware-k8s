#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE="$ROOT/experiments/evaluation/openmrs/concurrent-writer"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "=== CONCURRENT WRITER PREFLIGHT ==="

for command in kubectl ssh python3; do
    command -v "$command" >/dev/null ||
        fail "Missing executable: $command"
done

for node in k3s-worker1 k3s-worker2; do
    status="$(kubectl get node "$node" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"

    [[ "$status" == True ]] ||
        fail "$node is not Ready"

    echo "NODE_READY: $node"
done

[[ -n "${WRITER_TEST_NFS_HOST:-}" ]] ||
    fail "WRITER_TEST_NFS_HOST is required"

[[ -n "${WRITER_TEST_NFS_EXPORT:-}" ]] ||
    fail "WRITER_TEST_NFS_EXPORT is required"

[[ -n "${WRITER_TEST_NFS_IDENTITY:-}" ]] ||
    fail "WRITER_TEST_NFS_IDENTITY is required"

[[ "${WRITER_TEST_ISOLATED:-false}" == true ]] ||
    fail "Independent NFS isolation has not been confirmed"

[[ "${WRITER_TEST_DISPOSABLE:-false}" == true ]] ||
    fail "Disposable database storage has not been confirmed"

[[ "${WRITER_TEST_NFS_HOST}" != "${STORAGE_SERVER_SSH:-}" ]] ||
    fail "Experimental NFS host matches configured storage host"

[[ "${WRITER_TEST_NFS_EXPORT}" == /* ]] ||
    fail "NFS export must be an absolute path"

[[ "${WRITER_TEST_NFS_EXPORT}" != "/" ]] ||
    fail "NFS root export is prohibited"

[[ "${WRITER_TEST_NFS_IDENTITY}" =~ ^[a-zA-Z0-9._-]+$ ]] ||
    fail "Invalid experiment identity"

mkdir -p "$BASE"

echo "EXPERIMENT_DIRECTORY=$BASE"
echo "NFS_HOST_CONFIGURED=true"
echo "NFS_EXPORT_CONFIGURED=true"
echo "ISOLATION_DECLARED=true"
echo
echo "PREFLIGHT_CONFIGURATION_PASSED"
echo "NOTE: Isolation declarations require independent verification."
echo "NO_CLUSTER_CHANGES"
