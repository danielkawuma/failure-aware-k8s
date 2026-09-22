#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

source "${SCRIPT_DIR}/scenario-d-config.sh"

ACTION="${1:-}"

case "${ACTION}" in
    fence|unfence|status)
        ;;
    *)
        echo "Usage:"
        echo "  $0 fence"
        echo "  $0 unfence"
        echo "  $0 status"
        exit 1
        ;;
esac

ssh \
    -i "${SSH_KEY}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "${STORAGE_SERVER_SSH}" \
    "sudo -n ${STORAGE_FENCE_REMOTE} ${ACTION}"