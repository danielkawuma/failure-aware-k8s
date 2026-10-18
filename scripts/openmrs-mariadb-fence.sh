#!/usr/bin/env bash
set -Eeuo pipefail
# Reuse the previously piloted NFS fence; never auto-unfence a live writer.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"
[[ "$ACTION" == preflight || "$ACTION" == fence || "$ACTION" == status ]] || {
  echo "Usage: $0 preflight|fence|status" >&2; exit 2;
}
NAMESPACE="${OPENMRS_DB_NAMESPACE:-openmrs37}"
DEPLOYMENT="${OPENMRS_DB_DEPLOYMENT:-openmrs-mariadb}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
[[ -f "$SSH_KEY" ]] || { echo "SSH key missing" >&2; exit 1; }
export SSH_KEY
DATA="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json)"
readarray -t INFO < <(printf '%s' "$DATA" | python3 -c '
import json,sys
x=json.load(sys.stdin); t=x["spec"]["template"]
labels=t["metadata"].get("labels",{})
assert labels.get("failure-aware.io/duplication-sensitive")=="true", "sensitivity label missing"
assert x["spec"].get("replicas")==1, "expected one replica"
assert any(v.get("persistentVolumeClaim",{}).get("claimName")=="openmrs-mariadb-data-nfs" for v in t["spec"].get("volumes",[])), "unexpected PVC"
print(x["metadata"]["uid"])
')
PODS="$(kubectl get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" -o json)"
readarray -t P < <(printf '%s' "$PODS" | python3 -c '
import json,sys
p=json.load(sys.stdin)["items"]
p=[x for x in p if not x["metadata"].get("deletionTimestamp")]
assert len(p)==1,"expected exactly one nonterminating database pod"
print(p[0]["metadata"]["name"])
print(p[0]["spec"].get("nodeName", ""))
')
POD="${P[0]}"; NODE="${P[1]}"
[[ -n "$NODE" ]] || { echo "Database node unresolved" >&2; exit 1; }
IP="$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid node IP" >&2; exit 1; }
export FAILURE_AWARE_FENCE_MODE=nfs
export FAILURE_AWARE_FENCE_WORKER_IP="$IP"
export FAILURE_AWARE_FENCE_WORKLOAD_ID="$NAMESPACE/$DEPLOYMENT"
export FAILURE_AWARE_FENCE_WORKLOAD_NODE="$NODE"
printf 'Database=%s Pod=%s Node=%s IP=%s\n' "$NAMESPACE/$DEPLOYMENT" "$POD" "$NODE" "$IP" >&2
if [[ "$ACTION" == preflight ]]; then
  echo 'PREFLIGHT_ONLY: no storage traffic modified'
  exit 0
fi
# Recheck that the target pod still maps to the same node immediately before fencing.
ACTUAL="$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')"
[[ "$ACTUAL" == "$NODE" ]] || { echo 'Pod placement changed; aborting' >&2; exit 1; }
"$ROOT/scripts/storage-fence.sh" "$ACTION"
