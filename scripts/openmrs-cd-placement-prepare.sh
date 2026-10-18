#!/usr/bin/env bash
set -Eeuo pipefail
# Planned maintenance only. Preserves original manifest by writing a backup.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${OPENMRS_CD_ALLOW_DB_RESTART:-false}" == true ]] || { echo 'Set OPENMRS_CD_ALLOW_DB_RESTART=true after backing up test DB' >&2; exit 1; }
DIR="$ROOT/experiments/evaluation/openmrs/scenario-c-d/placement-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$DIR"
kubectl get deployment openmrs-mariadb -n openmrs37 -o yaml > "$DIR/original-deployment.yaml"
NODE="$(kubectl get pod -n openmrs37 -l app=openmrs-mariadb -o jsonpath='{.items[0].spec.nodeName}')"
[[ -n "$NODE" ]] || exit 1
kubectl scale deployment openmrs-mariadb -n openmrs37 --replicas=0
kubectl wait --for=delete pod -n openmrs37 -l app=openmrs-mariadb --timeout=180s
# Remove hard selector and prefer original node, constrain to worker-only pool.
python3 - "$NODE" > "$DIR/patch.json" <<'PY'
import json,sys
node=sys.argv[1]
print(json.dumps({'spec':{'template':{'spec':{'nodeSelector':{'kubernetes.io/hostname':None},'affinity':{'nodeAffinity':{'requiredDuringSchedulingIgnoredDuringExecution':{'nodeSelectorTerms':[{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':['k3s-worker1','k3s-worker2','k3s-worker3','k3s-worker4']}]}]},'preferredDuringSchedulingIgnoredDuringExecution':[{'weight':100,'preference':{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':[node]}]}}]}}}}}}))
PY
kubectl patch deployment openmrs-mariadb -n openmrs37 --type=merge -p "$(cat "$DIR/patch.json")"
kubectl scale deployment openmrs-mariadb -n openmrs37 --replicas=1
kubectl rollout status deployment/openmrs-mariadb -n openmrs37 --timeout=600s
kubectl get pods -n openmrs37 -l app=openmrs-mariadb -o wide
printf 'Original deployment saved at %s\n' "$DIR/original-deployment.yaml"
