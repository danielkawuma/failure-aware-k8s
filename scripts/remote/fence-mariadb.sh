#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
WORKLOAD_ID="${2:-}"
WORKLOAD_NODE="${3:-}"

case "$ACTION" in
    fence)
        echo "[MARIADB] Fencing requested: $WORKLOAD_ID on $WORKLOAD_NODE" >&2
        echo "[MARIADB] No independently enforceable write revocation configured." >&2
        exit 1
        ;;

    status)
        echo "[MARIADB] FENCING_UNVERIFIED" >&2
        exit 1
        ;;

    unfence)
        echo "[MARIADB] Refusing automatic restoration of stale authority." >&2
        exit 1
        ;;

    *)
        echo "Usage: $0 {fence|status|unfence} workload_id node" >&2
        exit 2
        ;;
esac