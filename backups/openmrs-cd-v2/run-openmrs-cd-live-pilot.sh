#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
CONFIG_DIR="$ROOT/experiments/evaluation/openmrs/scenario-c-d"
RUN="$CONFIG_DIR/pilot-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"
exec > >(tee -a "$RUN/pilot.log") 2>&1
log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)] $*"; }
fail(){ log "ERROR: $*"; exit 1; }
: "${OPENMRS_CD_ACK_COLLATERAL_IMPACT:=false}"
: "${OPENMRS_CD_ACK_LIVE_WRITER_RISK:=false}"
[[ "$OPENMRS_CD_ACK_COLLATERAL_IMPACT" == true && "$OPENMRS_CD_ACK_LIVE_WRITER_RISK" == true ]] || fail 'Live test disabled: set both explicit acknowledgments; use isolated/backup test data only'
[[ -x "$ROOT/controller/target/debug/failure-aware-controller" ]] || fail 'Controller binary missing'
python3 "$ROOT/scripts/openmrs-cd-prepare.py" "$RUN/controller.json"
read -r ORIGINAL IP CANDIDATE < <(python3 - "$RUN/controller-authority.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x['node'],x['ip'],x['candidate'])
PY
)
[[ "$ORIGINAL" != "$CANDIDATE" ]] || fail 'Candidate is original node'
# No change to Deployment until verified recovery eligibility; hostname pin conflicts must be prepared in a separate maintenance window.
SELECTOR="$(kubectl get deployment openmrs-mariadb -n openmrs37 -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}')"
[[ -z "$SELECTOR" ]] || fail "MariaDB is pinned to $SELECTOR. Prepare flexible placement before live run; no fault injected."
# This pilot intentionally requires a preinstalled remote fault script.
POD_IP="$(kubectl get pod -n openmrs37 -l app=openmrs-mariadb -o jsonpath='{.items[0].status.podIP}')"
[[ "$POD_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Cannot resolve MariaDB Pod IP'
remote(){ timeout 20 ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "ubuntu@$IP" "sudo -n /usr/local/sbin/openmrs-cd-fault $1 $POD_IP"; }
# A reported active fence or transport failure is not a clean preflight.
export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL" OPENMRS_CD_ORIGINAL_IP="$IP"
if "$ROOT/scripts/openmrs-cd-fence-original.sh" status >"$RUN/initial-fence.log" 2>&1; then fail 'Fence already active'; fi
if ! grep -q 'NOT_FENCED' "$RUN/initial-fence.log"; then fail 'Fence state unknown (e.g. SSH timeout); refusing to proceed'; fi
timeout 15 ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "ubuntu@$IP" 'echo SSH_OK' >"$RUN/worker-ssh.log" 2>&1 || fail 'Original worker SSH unavailable before fault'
remote status >"$RUN/initial-fault.log" 2>&1 && fail 'Fault already active' 
# Controller HTTP probe must be accessible before fault and fail when DB is inaccessible.
python3 "$ROOT/scripts/openmrs-db-probe.py" --host 10.43.165.41 >"$RUN/db-probe.log" 2>&1 & PROBE_PID=$!
CONTROLLER_PID=''; FAULT_ATTEMPTED=false; FAULT_CLEARED=false
cleanup(){
 rc=$?; trap - EXIT INT TERM; set +e
 if [[ "$FAULT_ATTEMPTED" == true && "$FAULT_CLEARED" != true ]]; then remote clear >"$RUN/emergency-fault-clear.log" 2>&1 && FAULT_CLEARED=true; fi
 [[ -z "$CONTROLLER_PID" ]] || { kill "$CONTROLLER_PID" 2>/dev/null; wait "$CONTROLLER_PID" 2>/dev/null; }
 kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null
 kubectl get pods -n openmrs37 -o wide >"$RUN/final-pods.txt" 2>&1
 "$ROOT/scripts/openmrs-cd-fence-original.sh" status >"$RUN/final-fence.log" 2>&1
 # Never auto-unfence: old-writer reconciliation is a separate guarded operation.
 echo 'NFS fence state recorded. Never automatically unfence after a live writer test.'
 if ((rc==0)); then touch "$RUN/OBSERVATION_COMPLETE"; else touch "$RUN/INCOMPLETE"; fi
 log "Results: $RUN (exit=$rc)"; exit "$rc"
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
sleep 2
curl -fsS --max-time 3 http://127.0.0.1:18086/health || fail 'Independent TCP probe not healthy'
log 'Starting controller before fault'
FAILURE_AWARE_RECOVERY_TIMEOUT_MS=1200000 FAILURE_AWARE_FENCING_TIMEOUT_MS=120000 FAILURE_AWARE_CONTROLLER_CONFIG="$RUN/controller.json" "$ROOT/controller/target/debug/failure-aware-controller" >"$RUN/controller.log" 2>&1 & CONTROLLER_PID=$!
sleep 10
kill -0 "$CONTROLLER_PID" || fail 'Controller exited during preflight'
log "Applying control-plane partition to $ORIGINAL"
FAULT_ATTEMPTED=true
remote apply >"$RUN/fault-apply.log" 2>&1 || fail 'Remote fault application failed'
date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$RUN/fault-time.txt"
# Validate actual database TCP isolation from the controller host.
ISOLATED=false
for attempt in 1 2 3 4 5; do
 if ! curl -fsS --max-time 3 http://127.0.0.1:18086/health >"$RUN/post-fault-probe.txt" 2>&1; then ISOLATED=true; break; fi
 sleep 2
done
[[ "$ISOLATED" == true ]] || fail 'Database still reachable from independent probe; aborting without authorizing recovery' 
# Observe; do not independently patch/delete MariaDB Pods. Only controller may authorize recovery.
END=$((SECONDS + ${OPENMRS_CD_OBSERVE_SECONDS:-900}))
while ((SECONDS < END)); do
 kubectl get pods -n openmrs37 -l app=openmrs-mariadb -o wide >>"$RUN/pods-timeline.txt" 2>&1 || true
 if grep -q '\[RECOVERY VERIFIED\]' "$RUN/controller.log"; then log 'Controller reported recovery verified'; break; fi
 if grep -q 'RecoveryBlockedFencingFailed' "$RUN/controller.log"; then fail 'Fence failed; recovery blocked'; fi
 sleep 5
done
log 'Clearing network fault (NOT the NFS fence)'
remote clear >"$RUN/fault-clear.log" 2>&1 || fail 'Network fault clear failed'
FAULT_CLEARED=true
# Success means observation finished, not verified split-brain prevention.
log 'Pilot observation finished; inspect controller, NFS fence and clinical integrity before any unfence'
