#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
: "${SSH_KEY:=$HOME/.ssh/k8s-aware}"
[[ -f "$SSH_KEY" ]] || { echo 'SSH key missing' >&2; exit 1; }
[[ -x scripts/fault.sh && -x scripts/run-openmrs-integrated.sh ]] || { echo 'Required scripts missing/not executable' >&2; exit 1; }
[[ -f harness/config/openmrs-scenario-e.json ]] || { echo 'Harness config missing' >&2; exit 1; }
echo '=== LEGACY SCENARIO E STATUS ==='
output="$(timeout 25 scripts/fault.sh scenario-e show)" || { echo 'Fault status unavailable' >&2; exit 1; }
printf '%s\n' "$output"
grep -Eq '^none$' <<< "$output" || { echo 'Fault is active or status unknown' >&2; exit 1; }
echo '=== OPENMRS BACKEND ==='
kubectl get pods -n openmrs37 -l app=openmrs-backend -o wide
node="$(kubectl get pods -n openmrs37 -l app=openmrs-backend -o jsonpath='{.items[0].spec.nodeName}')"
[[ "$node" == k3s-worker1 ]] || { echo "Backend must be reset to k3s-worker1; currently $node" >&2; exit 1; }
echo '=== HEALTH ==='
health="${OPENMRS_CLINICAL_URL:-http://102.34.160.87:30366/openmrs/health/started}"
curl -fsS --connect-timeout 3 --max-time 10 "$health" >/dev/null
printf 'PREFLIGHT_OK: backend=%s profile fault inactive\n' "$node"
