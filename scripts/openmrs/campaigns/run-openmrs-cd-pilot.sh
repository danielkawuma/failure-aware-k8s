#!/usr/bin/env bash
set -Eeuo pipefail
# Safety-gated inspection only. Never substitutes stop-before-fence for a live-writer test.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NAMESPACE="${OPENMRS_DB_NAMESPACE:-openmrs37}"
DEPLOYMENT="${OPENMRS_DB_DEPLOYMENT:-openmrs-mariadb}"
OUT="$ROOT/experiments/evaluation/openmrs/scenario-c-d/preflight-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json > "$OUT/deployment.json"
kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o wide > "$OUT/pods.txt"
kubectl get pvc -n "$NAMESPACE" -o wide > "$OUT/pvcs.txt"
python3 - "$OUT/deployment.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); t=x['spec']['template']; labels=t['metadata'].get('labels',{})
assert labels.get('failure-aware.io/duplication-sensitive')=='true', 'Database must be duplication-sensitive'
assert x['spec']['replicas']==1, 'Expected one database replica'
print('Duplication-sensitive workload discovered; no fault or fencing applied.')
PY
printf '%s\n' 'LIVE_WRITER_FENCING_NOT_VALIDATED' > "$OUT/SAFETY_GATE"
echo "Evidence: $OUT"
echo 'STOP: A real live-writer C+D pilot requires independently verified exclusion and a protected database clone.'
