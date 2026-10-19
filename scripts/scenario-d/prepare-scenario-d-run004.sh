#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only Scenario D follow-up preparation. Never unfences or injects faults.
ROOT="${FAILURE_AWARE_ROOT:-$HOME/failure-aware-k8s}"
cd "$ROOT"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="experiments/evaluation/openmrs/scenario-c-d/preflight-run004-$RUN_ID"
mkdir -p "$OUT"
exec > >(tee "$OUT/preflight.log") 2>&1
printf 'RUN_ID=%s\nOUT=%s\n' "$RUN_ID" "$OUT"
export SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
export OPENMRS_CD_ORIGINAL_NODE=k3s-worker3
export OPENMRS_CD_ORIGINAL_IP=102.34.160.36
printf '\n=== Original runtime (read only) ===\n'
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 ubuntu@102.34.160.36 \
  'sudo -n ps -eo pid,ppid,stat,etime,comm,args | grep -E "[m]ariadbd|[m]ysqld" || true' \
  | tee "$OUT/original-processes.txt"
printf '\n=== Pods ===\n'
kubectl get pods -n openmrs37 -l app=openmrs-mariadb -o wide | tee "$OUT/pods.txt"
printf '\n=== Placement ===\n'
kubectl get deployment openmrs-mariadb -n openmrs37 -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}' | tee "$OUT/placement.txt"
printf '\n=== Fence ===\n'
set +e
scripts/openmrs-cd-fence-original.sh status > "$OUT/fence.txt" 2>&1
FENCE_RC=$?
set -e
cat "$OUT/fence.txt"
printf 'FENCE_EXIT_CODE=%s\n' "$FENCE_RC"
printf '\n=== Decision ===\n'
# A clean rerun requires no original writer, an inactive fence, and the database back on worker3.
if grep -Eq '[[:space:]](mariadbd|mysqld)([[:space:]]|$)' "$OUT/original-processes.txt"; then
  echo 'BLOCKED: Original database runtime remains on worker3.'
  echo 'Do not remove the fence or start the next fault run.'
  exit 20
fi
if [[ "$FENCE_RC" -ne 1 ]] || ! grep -qx 'NOT_FENCED' "$OUT/fence.txt"; then
  echo 'BLOCKED: Original NFS fence is active or not conclusively inactive.'
  exit 21
fi
if ! grep -q 'k3s-worker3' "$OUT/placement.txt"; then
  echo 'BLOCKED: MariaDB is not restored to original worker3 baseline.'
  exit 22
fi
echo 'PRELIMINARY_BASELINE_CHECKS_PASSED'
echo 'Manual independent writer-authority and data-integrity approval still required before fault injection.'

