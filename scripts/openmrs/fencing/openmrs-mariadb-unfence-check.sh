#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only reconciliation gate. This script never removes the fence.
NS="${OPENMRS_DB_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_DB_DEPLOYMENT:-openmrs-mariadb}"
OLD_NODE="${OPENMRS_OLD_DB_NODE:?Set OPENMRS_OLD_DB_NODE to the fenced node}"
NEW_NODE="${OPENMRS_NEW_DB_NODE:?Set OPENMRS_NEW_DB_NODE to the recovery node}"
[[ "$OLD_NODE" != "$NEW_NODE" ]] || exit 1
PODS="$(kubectl get pods -n "$NS" -l "app=$DEP" -o json)"
printf '%s' "$PODS" | python3 -c '
import json,sys
old,new=sys.argv[1:]
p=json.load(sys.stdin)["items"]
assert len(p)==1, "exactly one pod required, including terminating pods"
x=p[0]
assert not x["metadata"].get("deletionTimestamp"),"pod terminating"
assert x["spec"].get("nodeName")==new,"replacement on wrong node"
assert x["status"].get("phase")=="Running","replacement not running"
assert any(c.get("type")=="Ready" and c.get("status")=="True" for c in x["status"].get("conditions",[])),"replacement not Ready"
' "$OLD_NODE" "$NEW_NODE"
IP="$(kubectl get node "$OLD_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "ubuntu@$IP" \
  "sudo -n k3s crictl ps --label io.kubernetes.pod.namespace=$NS --label io.kubernetes.container.name=mariadb -q" \
  | grep -q . && { echo 'Old MariaDB container still running' >&2; exit 1; }
echo 'CHECKS_PASSED: current old container absent and replacement Ready.'
echo 'NOT AUTHORIZED TO UNFENCE: verify durable restart exclusion separately.'
