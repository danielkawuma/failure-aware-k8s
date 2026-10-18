#!/usr/bin/env bash
set -Eeuo pipefail
# Disruptive setup ONLY for dedicated OpenMRS benchmark environment.
# Eliminates conflicting hostname selector; a soft preference keeps initial placement on Worker1.
[[ ${OPENMRS_ALLOW_RECREATE:-false} == true ]] || { echo 'Set OPENMRS_ALLOW_RECREATE=true after backup and maintenance approval' >&2; exit 1; }
NS=openmrs37; DEP=openmrs-backend
kubectl get deployment "$DEP" -n "$NS" -o json > "${OPENMRS_BACKUP_PATH:-/tmp/openmrs-backend-before-placement.json}"
python3 - <<'PY' > /tmp/openmrs-placement-patch.json
import json
print(json.dumps({'spec':{'template':{'spec':{'nodeSelector':{'kubernetes.io/hostname':None},'affinity':{'nodeAffinity':{'preferredDuringSchedulingIgnoredDuringExecution':[{'weight':100,'preference':{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':['k3s-worker1']}]}}]}}}}}}))
PY
kubectl scale deployment "$DEP" -n "$NS" --replicas=0
kubectl wait --for=delete pod -l app=openmrs-backend -n "$NS" --timeout=240s
kubectl patch deployment "$DEP" -n "$NS" --type=merge --patch-file /tmp/openmrs-placement-patch.json
kubectl scale deployment "$DEP" -n "$NS" --replicas=1
kubectl rollout status deployment/"$DEP" -n "$NS" --timeout=600s
kubectl get pods -n "$NS" -l app=openmrs-backend -o wide
