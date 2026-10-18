#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SCENARIOS="${SCENARIOS:-scenario-b,scenario-c}"
MODES="${MODES:-V0,T5,T10,T30,FA1}"
RUNS="${RUNS_PER_MODE:-2}"; START="${START_RUN:-3}"
PAUSE="${RESET_SECONDS:-60}"; TIMEOUT="${RUN_TIMEOUT_SECONDS:-2400}"
B_RUNNER="$ROOT/scripts/run-openmrs-experiment.sh"
C_RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
CD_RUNNER="$ROOT/scripts/run-openmrs-cd-campaign.sh"
E_RUNNER="$ROOT/scripts/run-openmrs-e-campaign.sh"
RESET="$ROOT/scripts/openmrs-backend-reset.sh"
FAULT="$ROOT/scripts/fault.sh"
OUT="$ROOT/experiments/evaluation/openmrs/campaigns/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$OUT"; exec > >(tee -a "$OUT/campaign.log") 2>&1
SUMMARY="$OUT/summary.csv"; PLAN="$OUT/plan.csv"
printf 'scenario,mode,run,status,start_utc,end_utc,exit_code\n' > "$SUMMARY"
printf 'scenario,mode,run\n' > "$PLAN"
fail(){ echo "ERROR: $*" >&2; exit 1; }
for n in "$RUNS" "$START" "$PAUSE" "$TIMEOUT"; do [[ "$n" =~ ^[0-9]+$ ]] || fail 'Invalid numeric setting'; done
(( RUNS>0 && TIMEOUT>0 )) || fail 'Invalid run count or timeout'
IFS=',' read -r -a scenarios <<< "$SCENARIOS"
IFS=',' read -r -a modes <<< "$MODES"
for mode in "${modes[@]}"; do case "$mode" in V0|T5|T10|T30|FA1) ;; *) fail "Unknown mode $mode";; esac; done
for scenario in "${scenarios[@]}"; do
 case "$scenario" in scenario-b|scenario-c|scenario-c-d|scenario-e) ;; *) fail "Unknown scenario $scenario";; esac
 for ((i=0;i<RUNS;i++)); do
  id="$(printf '%03d' "$((10#$START+i))")"
  if [[ "$scenario" == scenario-c-d ]]; then
   printf '%s,%s,%s\n' "$scenario" FA1 "$id" >> "$PLAN"
  elif [[ "$scenario" == scenario-e ]]; then
   printf '%s,%s,%s\n' "$scenario" DELEGATED "$id" >> "$PLAN"
  else
   mapfile -t order < <(printf '%s\n' "${modes[@]}" | shuf)
   for mode in "${order[@]}"; do
    dir="$ROOT/experiments/evaluation/openmrs/$scenario/$mode/run-$id"
    [[ ! -e "$dir" ]] || fail "Existing run: $dir"
    printf '%s,%s,%s\n' "$scenario" "$mode" "$id" >> "$PLAN"
   done
  fi
 done
done
echo "Campaign plan: $PLAN"
if [[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" != true ]]; then echo 'PLAN ONLY'; exit 0; fi
[[ "${OPENMRS_ENABLE_FAULTS:-false}" == true ]] || fail 'Faults not enabled'
[[ -f "${SSH_KEY:-$HOME/.ssh/k8s-aware}" ]] || fail 'SSH key missing'
for s in "${scenarios[@]}"; do
 case "$s" in
  scenario-b) [[ -x "$B_RUNNER" && -x "$RESET" ]] || fail 'B runner/reset missing';;
  scenario-c) [[ -x "$C_RUNNER" && -x "$RESET" ]] || fail 'C runner/reset missing';;
  scenario-c-d) [[ -x "$CD_RUNNER" ]] || fail 'Dedicated C+D runner missing';;
  scenario-e) [[ -x "$E_RUNNER" ]] || fail 'Dedicated E runner missing';;
 esac
done
# Delegate whole specialized campaigns to their lifecycle-aware runners.
# Mixed campaigns execute in scenario order, one after another.
for scenario in "${scenarios[@]}"; do
 if [[ "$scenario" == scenario-c-d ]]; then
  echo 'START dedicated C+D campaign'
  RUNS_PER_MODE="$RUNS" START_RUN="$START" "$CD_RUNNER" || fail 'C+D campaign failed'
  echo 'COMPLETE dedicated C+D campaign'; continue
 fi
 if [[ "$scenario" == scenario-e ]]; then
  echo 'START dedicated E campaign'
  RUNS_PER_MODE="$RUNS" START_RUN="$START" MODES="$MODES" "$E_RUNNER" || fail 'E campaign failed'
  echo 'COMPLETE dedicated E campaign'; continue
 fi
 while IFS=',' read -r planned mode id; do
  [[ "$planned" == "$scenario" ]] || continue
  dir="$ROOT/experiments/evaluation/openmrs/$scenario/$mode/run-$id"
  [[ ! -e "$dir" ]] || fail "Existing run: $dir"
  echo "PREPARING $scenario/$mode/$id"
  "$RESET" || fail 'Backend reset failed; no fault injected'
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rc=0
  if [[ "$scenario" == scenario-b ]]; then
   timeout --signal=TERM --kill-after=30s "${TIMEOUT}s" "$B_RUNNER" scenario-b "$mode" "$id" || rc=$?
  else
   timeout --signal=TERM --kill-after=30s "${TIMEOUT}s" "$C_RUNNER" scenario-c "$mode" "$id" || rc=$?
  fi
  finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  status=FAILED
  if (( rc==0 )) && [[ -f "$dir/COMPLETE" ]] && [[ ! -e "$dir/INCOMPLETE" ]]; then status=OBSERVATION_COMPLETE; fi
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$scenario" "$mode" "$id" "$status" "$started" "$finished" "$rc" >> "$SUMMARY"
  [[ "$status" == OBSERVATION_COMPLETE ]] || fail "Experiment failed: $scenario/$mode/$id"
  sleep "$PAUSE"
 done < "$PLAN"
done
echo "Campaign observations complete: $OUT"
