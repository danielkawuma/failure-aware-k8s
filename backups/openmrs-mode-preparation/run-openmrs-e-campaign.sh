#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
FAULT="$ROOT/scripts/fault.sh"
RESET="$ROOT/scripts/openmrs-backend-reset.sh"
MODES_CSV="${MODES:-V0,T5,T10,T30,FA1}"
PROFILES_CSV="${OPENMRS_E_PROFILES:-mild,moderate,severe}"
RUNS="${RUNS_PER_MODE:-2}"; START="${START_RUN:-3}"
PAUSE="${RESET_SECONDS:-60}"; RUN_TIMEOUT="${RUN_TIMEOUT_SECONDS:-2400}"
CAMPAIGN="$ROOT/experiments/evaluation/openmrs/campaigns/e-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$CAMPAIGN"
exec > >(tee -a "$CAMPAIGN/campaign.log") 2>&1
SUMMARY="$CAMPAIGN/summary.csv"; PLAN="$CAMPAIGN/plan.csv"
printf 'profile,mode,run,status,started,finished,exit_code\n' > "$SUMMARY"
printf 'profile,mode,run\n' > "$PLAN"
fail(){ echo "ERROR: $*" >&2; exit 1; }
for n in "$RUNS" "$START" "$PAUSE" "$RUN_TIMEOUT"; do [[ "$n" =~ ^[0-9]+$ ]] || fail 'Invalid numeric setting'; done
(( RUNS>0 && RUN_TIMEOUT>0 )) || fail 'Invalid run count/timeout'
[[ -x "$RUNNER" && -x "$FAULT" && -x "$RESET" ]] || fail 'Runner, fault or reset script missing/not executable'
[[ -f "${SSH_KEY:-$HOME/.ssh/k8s-aware}" ]] || fail 'SSH key missing'
IFS=',' read -r -a MODE_ARRAY <<< "$MODES_CSV"
IFS=',' read -r -a PROFILE_ARRAY <<< "$PROFILES_CSV"
for m in "${MODE_ARRAY[@]}"; do case "$m" in V0|T5|T10|T30|FA1) ;; *) fail "Invalid mode $m";; esac; done
for p in "${PROFILE_ARRAY[@]}"; do case "$p" in mild|moderate|severe) ;; *) fail "Invalid profile $p";; esac; done
check_fault_clear(){ local o; o="$(timeout 25 "$FAULT" scenario-e show 2>&1)" || return 1; grep -Eq '^none$' <<< "$o"; }
for ((i=0;i<RUNS;i++)); do
 id="$(printf '%03d' "$((10#$START+i))")"
 mapfile -t order < <(printf '%s\n' "${MODE_ARRAY[@]}" | shuf)
 for mode in "${order[@]}"; do
  for profile in "${PROFILE_ARRAY[@]}"; do
   dir="$ROOT/experiments/evaluation/openmrs/scenario-e/$profile/$mode/run-$id"
   [[ ! -e "$dir" ]] || fail "Existing run: $dir"
   printf '%s,%s,%s\n' "$profile" "$mode" "$id" >> "$PLAN"
  done
 done
done
printf 'Scenario E plan: %s\n' "$PLAN"
if [[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" != true ]]; then echo 'PLAN ONLY'; exit 0; fi
[[ "${OPENMRS_ENABLE_FAULTS:-false}" == true ]] || fail 'Fault execution not enabled'
while IFS=',' read -r profile mode id; do
 [[ "$profile" == profile ]] && continue
 dir="$ROOT/experiments/evaluation/openmrs/scenario-e/$profile/$mode/run-$id"
 [[ ! -e "$dir" ]] || fail "Existing results: $dir"
 check_fault_clear || fail 'Scenario E fault not confirmed cleared'
 echo "PREPARING backend: $profile/$mode/$id"
 "$RESET" || fail 'Backend placement reset failed'
 started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
 rc=0
 timeout --signal=TERM --kill-after=30s "${RUN_TIMEOUT}s" "$RUNNER" scenario-e "$mode" "$id" "$profile" || rc=$?
 finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
 status=FAILED
 if (( rc==0 )) && [[ -f "$dir/COMPLETE" ]] && [[ ! -e "$dir/INCOMPLETE" ]] && check_fault_clear; then status=OBSERVATION_COMPLETE; fi
 printf '%s,%s,%s,%s,%s,%s,%s\n' "$profile" "$mode" "$id" "$status" "$started" "$finished" "$rc" >> "$SUMMARY"
 [[ "$status" == OBSERVATION_COMPLETE ]] || fail "Run failed: $profile/$mode/$id"
 sleep "$PAUSE"
done < "$PLAN"
echo "Campaign observations complete: $CAMPAIGN"
