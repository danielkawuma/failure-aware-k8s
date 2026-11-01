#!/usr/bin/env bash
# OpenMRS Scenario B under clinical load.
# Starts the load generator, runs the existing Scenario B campaign for the
# chosen modes, then stops the load. Every run directory keeps its own
# fault-start-time.txt and fault-clear-time.txt; the load CSV is joined
# with them by analysis/analyze-openmrs-load.py.
#
# Usage (from the repository root, on the runner host):
#   export SSH_KEY=~/.ssh/k8s-aware OPENMRS_USER=admin OPENMRS_PASS='...'
#   OPENMRS_BASE_URL=http://<worker2-ip>:30366/openmrs \
#   MODES=V0,T10,T30,FA1 RUNS_PER_MODE=5 START_RUN=101 FAULT_SECONDS=600 \
#   bash scripts/openmrs/load/run-openmrs-load-campaign.sh
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"; cd "$ROOT"
: "${OPENMRS_BASE_URL:?set OPENMRS_BASE_URL}" "${OPENMRS_USER:?}" "${OPENMRS_PASS:?}" "${SSH_KEY:?}"
export MODES="${MODES:-V0,T10,T30,FA1}" RUNS_PER_MODE="${RUNS_PER_MODE:-5}" START_RUN="${START_RUN:-101}"
export FAULT_SECONDS="${FAULT_SECONDS:-600}" SCENARIOS=scenario-b OPENMRS_CAMPAIGN_EXECUTE=true
OUT="$ROOT/experiments/evaluation/openmrs/load/campaign-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"; exec > >(tee -a "$OUT/campaign.log") 2>&1
log() { printf '[LOAD %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Preflight: the gateway must answer before load starts.
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$OPENMRS_USER:$OPENMRS_PASS" --max-time 10 "$OPENMRS_BASE_URL/ws/rest/v1/session" || true)
[[ "$code" == 200 ]] || { log "Gateway not ready (HTTP $code); bring OpenMRS up first."; exit 1; }
printf 'modes=%s\nruns_per_mode=%s\nstart_run=%s\nfault_seconds=%s\nusers=%s\nbase_url=%s\ncommit=%s\n' \
  "$MODES" "$RUNS_PER_MODE" "$START_RUN" "$FAULT_SECONDS" "${LOAD_USERS:-10}" "$OPENMRS_BASE_URL" "$(git rev-parse --short HEAD)" > "$OUT/campaign.env"

export LOAD_OUT="$OUT/load.csv" LOAD_STOP_FILE="$OUT/STOP"
python3 tools/openmrs-load/load.py & LOAD_PID=$!
trap 'touch "$LOAD_STOP_FILE"; wait $LOAD_PID 2>/dev/null || true' EXIT
log "Load started (pid $LOAD_PID, ${LOAD_USERS:-10} users); 120 s warm-up"
sleep 120

log "Scenario B campaign: modes=$MODES runs=$RUNS_PER_MODE from run $START_RUN, fault ${FAULT_SECONDS}s"
bash scripts/openmrs/campaigns/run-openmrs-all-campaigns.sh || log "Campaign runner exited with $?"
log "Campaign finished; 60 s cool-down"; sleep 60
touch "$LOAD_STOP_FILE"; wait $LOAD_PID || true
echo "$OUT" > "$ROOT/experiments/evaluation/openmrs/load/LATEST"
log "Done. Load record: $OUT/load.csv"
