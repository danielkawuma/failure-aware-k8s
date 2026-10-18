#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${OPENMRS_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_BACKEND_DEPLOYMENT:-openmrs-backend}"
TARGET="${OPENMRS_BACKEND_FAULT_NODE:-k3s-worker1}"
TIMEOUT="${OPENMRS_RESET_TIMEOUT_SECONDS:-1200}"
HEALTH="${OPENMRS_HEALTH_URL:-http://102.34.160.87:30366/openmrs/health/started}"
log(){ printf '[BACKEND RESET] %s\n' "$*"; }
fail(){ log "ERROR: $*" >&2; exit 1; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && (( TIMEOUT > 0 )) || fail 'Invalid reset timeout'
[[ "$TARGET" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail 'Invalid target node'
command -v kubectl >/dev/null || fail 'kubectl missing'
node_ready(){ [[ "$(kubectl --request-timeout=10s get node "$TARGET" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]] && [[ "$(kubectl --request-timeout=10s get node "$TARGET" -o jsonpath='{.spec.unschedulable}')" != true ]]; }
node_ready || fail "Target $TARGET not Ready/schedulable"
# Worker-only affinity is required even after temporary pin removal.
AFFINITY="$(python3 - "$TARGET" <<'PY'
import json,sys
node=sys.argv[1]
print(json.dumps({'nodeAffinity':{'requiredDuringSchedulingIgnoredDuringExecution':{'nodeSelectorTerms':[{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':['k3s-worker1','k3s-worker2','k3s-worker3','k3s-worker4']}]}]},'preferredDuringSchedulingIgnoredDuringExecution':[{'weight':100,'preference':{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':[node]}]}}]}}))
PY
)"
# Confirm no unexpected pre-existing selector keys that would conflict with pinning.
CURRENT_SELECTOR="$(kubectl --request-timeout=10s get deployment "$DEP" -n "$NS" -o jsonpath='{.spec.template.spec.nodeSelector}')"
log "Current nodeSelector: ${CURRENT_SELECTOR:-<none>}"
# Phase 1: force scheduling to the target node, with Recreate strategy preserved.
log "Temporarily pinning backend to $TARGET"
PATCH="$(python3 - "$TARGET" "$AFFINITY" <<'PY'
import json,sys
print(json.dumps({'spec':{'template':{'spec':{'nodeSelector':{'kubernetes.io/hostname':sys.argv[1]},'affinity':json.loads(sys.argv[2])}}}}))
PY
)"
kubectl patch deployment "$DEP" -n "$NS" --type=merge -p "$PATCH" >/dev/null
kubectl rollout status deployment/"$DEP" -n "$NS" --timeout="${TIMEOUT}s" || fail 'Pinned rollout failed; leaving current state for inspection'
# Phase 2: remove temporary selector. Kubernetes may restart the pod again.
log 'Removing temporary hostname selector; retaining required worker affinity'
kubectl patch deployment "$DEP" -n "$NS" --type=json -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]' >/dev/null || fail 'Unable to remove temporary hostname selector'
kubectl rollout status deployment/"$DEP" -n "$NS" --timeout="${TIMEOUT}s" || fail 'Flexible rollout failed'
# Preferred affinity is not a guarantee: fail rather than injecting against the wrong node.
verify(){
  kubectl --request-timeout=10s get deployment "$DEP" -n "$NS" -o json | python3 -c '
import json,sys
x=json.load(sys.stdin); s=x["spec"]["template"]["spec"]
assert not s.get("nodeSelector",{}).get("kubernetes.io/hostname"), "hostname pin remains"
a=s.get("affinity",{}).get("nodeAffinity",{}).get("requiredDuringSchedulingIgnoredDuringExecution",{}).get("nodeSelectorTerms",[])
assert a, "worker-only affinity missing"
' && kubectl --request-timeout=10s get pods -n "$NS" -l app=openmrs-backend -o json | python3 -c '
import json,sys
items=json.load(sys.stdin)["items"]
ready=[p for p in items if not p["metadata"].get("deletionTimestamp") and p["spec"].get("nodeName")==sys.argv[1] and p["status"].get("phase")=="Running" and any(c.get("type")=="Ready" and c.get("status")=="True" for c in p["status"].get("conditions",[]))]
assert len(ready)==1 and len([p for p in items if not p["metadata"].get("deletionTimestamp")])==1, "wrong active backend placement"
' "$TARGET" && curl -fsS --connect-timeout 3 --max-time 10 "$HEALTH" >/dev/null
}
DEADLINE=$((SECONDS+TIMEOUT))
until verify; do
  (( SECONDS < DEADLINE )) || fail 'Backend not healthy on target after flexible rollout; no fault should be injected'
  sleep 5
done
log "READY: backend on $TARGET, no hostname pin, clinical health OK"
