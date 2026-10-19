#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only Scenario C -> D -> F integration preflight.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NS="${OPENMRS_DB_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_DB_DEPLOYMENT:-openmrs-mariadb}"
SELECTOR="app=${DEP}"
export SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
[[ -f "$SSH_KEY" ]] || { echo 'SSH key missing' >&2; exit 1; }
command -v kubectl >/dev/null
command -v python3 >/dev/null
D="$(kubectl get deployment "$DEP" -n "$NS" -o json)"
P="$(kubectl get pods -n "$NS" -l "$SELECTOR" -o json)"
readarray -t V < <(python3 -c '
import json,sys
D=json.load(open(sys.argv[1])); P=json.load(open(sys.argv[2]))
t=D["spec"]["template"]
assert t["metadata"]["labels"].get("failure-aware.io/duplication-sensitive")=="true", "sensitivity label missing"
assert D["spec"].get("replicas")==1,"expected one replica"
assert any(v.get("persistentVolumeClaim",{}).get("claimName")=="openmrs-mariadb-data-nfs" for v in t["spec"].get("volumes",[])), "unexpected database PVC"
p=P["items"]
assert len(p)==1 and not p[0]["metadata"].get("deletionTimestamp"),"expected one nonterminating Pod"
x=p[0]; assert x["status"].get("phase")=="Running", "database not running"
assert any(c.get("type")=="Ready" and c.get("status")=="True" for c in x["status"].get("conditions",[])),"database not Ready"
print(x["metadata"]["name"]); print(x["spec"]["nodeName"])
' <(printf '%s' "$D") <(printf '%s' "$P"))
POD="${V[0]}"; NODE="${V[1]}"
IP="$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
[[ -n "$IP" ]] || { echo 'Original worker IP missing' >&2; exit 1; }
export FAILURE_AWARE_FENCE_MODE=nfs
export FAILURE_AWARE_FENCE_WORKER_IP="$IP"
export FAILURE_AWARE_FENCE_WORKLOAD_ID="$NS/$DEP"
export FAILURE_AWARE_FENCE_WORKLOAD_NODE="$NODE"
echo "Original writer: $NS/$POD node=$NODE ip=$IP"
CANDIDATES="$(kubectl get nodes -l failure-aware.io/role=recovery-candidate -o json)"
python3 -c '
import json,sys
old=sys.argv[1]
items=json.load(sys.stdin)["items"]
valid=[]
for n in items:
 name=n["metadata"]["name"]
 if name==old or n["spec"].get("unschedulable",False):continue
 if not any(c.get("type")=="Ready" and c.get("status")=="True" for c in n["status"].get("conditions",[])):continue
 if any(t.get("effect") in ("NoSchedule","NoExecute") for t in n["spec"].get("taints",[])):continue
 valid.append(name)
print("Ready candidate nodes:", ", ".join(valid) if valid else "NONE")
if not valid:sys.exit(1)
' "$NODE" <<< "$CANDIDATES"
if "$ROOT/scripts/storage-fence.sh" status; then
 echo 'WARNING: existing fence active; do not start another experiment' >&2
 exit 1
else
 echo 'Fence not reported active; distinguish NOT_FENCED from transport failure in remote logs.'
fi
echo 'READ_ONLY_PREFLIGHT_COMPLETE: no fault injected, no recovery authorized.'
