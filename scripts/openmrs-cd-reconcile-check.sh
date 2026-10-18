#!/usr/bin/env bash
# Read-only reconciliation evidence; deliberately does NOT unfence.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTHORITY_FILE="${1:?Usage: $0 /path/to/controller-authority.json}"
read -r ORIGINAL IP CANDIDATE < <(python3 - "$AUTHORITY_FILE" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x['node'],x['ip'],x['candidate'])
PY
)
export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL" OPENMRS_CD_ORIGINAL_IP="$IP"
echo "Original=$ORIGINAL Candidate=$CANDIDATE"
echo '=== FENCE STATUS ==='
set +e
"$ROOT/scripts/openmrs-cd-fence-original.sh" status
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo 'Fence not verified active; do not authorize unfence' >&2; exit 1; }
echo '=== ORIGINAL RUNTIME ==='
ORIGINAL_IDS="$(timeout 15 ssh -i "${SSH_KEY:-$HOME/.ssh/k8s-aware}" -o BatchMode=yes -o ConnectTimeout=5 "${OPENMRS_CD_SSH_USER:-ubuntu}@$IP" "sudo -n k3s crictl ps --label io.kubernetes.pod.namespace=${OPENMRS_CD_NAMESPACE:-openmrs37} --label io.kubernetes.container.name=mariadb -q")" || {
 echo 'Original runtime unreachable; cannot establish absence' >&2; exit 1;
}
[[ -z "$ORIGINAL_IDS" ]] || { echo "Old MariaDB container still running: $ORIGINAL_IDS" >&2; exit 1; }
echo '=== REPLACEMENT PODS ==='
kubectl get pods -n "${OPENMRS_CD_NAMESPACE:-openmrs37}" -l "${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}" -o wide
echo 'OLD_RUNTIME_ABSENT: additional restart-prevention and data-integrity checks required before unfencing'
