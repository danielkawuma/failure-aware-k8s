#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ACTION="${1:-}"
case "$ACTION" in fence|status|unfence) ;; *) echo 'Usage: openmrs-cd-fence-original.sh fence|status|unfence' >&2; exit 2;; esac
: "${OPENMRS_CD_ORIGINAL_NODE:?Must set original node before fault}"
: "${OPENMRS_CD_ORIGINAL_IP:?Must set original node IP before fault}"
[[ "$OPENMRS_CD_ORIGINAL_NODE" =~ ^k3s-worker[0-9]+$ ]] || exit 2
[[ "$OPENMRS_CD_ORIGINAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
export FAILURE_AWARE_FENCE_MODE=nfs
export FAILURE_AWARE_FENCE_WORKER_IP="$OPENMRS_CD_ORIGINAL_IP"
export FAILURE_AWARE_FENCE_WORKLOAD_NODE="$OPENMRS_CD_ORIGINAL_NODE"
export FAILURE_AWARE_FENCE_WORKLOAD_ID=openmrs37/openmrs-mariadb
exec "$ROOT/scripts/storage-fence.sh" "$ACTION"
