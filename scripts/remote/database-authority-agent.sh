#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
WORKLOAD_ID="${2:-}"
WORKLOAD_NODE="${3:-}"

ENGINE="${FAILURE_AWARE_DATABASE_ENGINE:-}"
ADAPTER_DIR="${FAILURE_AWARE_ADAPTER_DIR:-/usr/local/lib/failure-aware}"

fail() {
    printf '[AUTHORITY] ERROR: %s\n' "$*" >&2
    exit 1
}

case "$ACTION" in
    fence|status|unfence) ;;
    *) fail "Unsupported action: $ACTION" ;;
esac

[[ "$WORKLOAD_ID" =~ ^[a-zA-Z0-9._/-]+$ ]] ||
    fail "Invalid workload identity"

[[ "$WORKLOAD_NODE" =~ ^[a-zA-Z0-9._-]+$ ]] ||
    fail "Invalid workload node"

case "$ENGINE" in
    mariadb|postgresql) ;;
    *) fail "Unsupported or missing database engine" ;;
esac

case "$ENGINE" in
    mariadb)
        ADAPTER="${ADAPTER_DIR}/fence-mariadb.sh"
        ;;
    postgresql)
        ADAPTER="${ADAPTER_DIR}/fence-postgresql.sh"
        ;;
esac

[[ -x "$ADAPTER" ]] ||
    fail "Fencing adapter unavailable: $ADAPTER"

printf '[AUTHORITY] action=%s engine=%s workload=%s node=%s\n' \
    "$ACTION" "$ENGINE" "$WORKLOAD_ID" "$WORKLOAD_NODE" >&2

"$ADAPTER" "$ACTION" "$WORKLOAD_ID" "$WORKLOAD_NODE"