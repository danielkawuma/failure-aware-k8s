#!/usr/bin/env bash
set -Eeuo pipefail
# Separate OpenMRS backend fault, leaving the legacy Nginx fault script unchanged.
ACTION=${1:?Usage: openmrs-c-fault.sh apply|status|clear|absent [pod-ip]}
POD_IP=${2:-}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/k8s-aware}
HOST=${OPENMRS_FAULT_HOST:-ubuntu@102.34.160.87}
REMOTE=${OPENMRS_REMOTE_FAULT:-/usr/local/sbin/openmrs-backend-fault}
case "$ACTION" in apply|status|clear|absent) ;; *) exit 2;; esac
if [[ "$ACTION" == apply ]]; then
  [[ "$POD_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
fi
if [[ "$ACTION" == absent ]]; then
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
    "sudo -n test ! -e /run/openmrs-backend-fault-ip && ! sudo -n iptables -C OUTPUT -p tcp -d 102.34.160.89 --dport 6443 -j DROP 2>/dev/null"
  exit $?
fi
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
  sudo -n "$REMOTE" "$ACTION" "$POD_IP"
