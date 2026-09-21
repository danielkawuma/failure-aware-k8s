#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

source "${SCRIPT_DIR}/experiment-config.sh"

ssh \
  -i "${SSH_KEY}" \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  "${WORKER1_SSH}" \
  sudo -n \
  /usr/local/sbin/failure-aware-fault \
  "$@"