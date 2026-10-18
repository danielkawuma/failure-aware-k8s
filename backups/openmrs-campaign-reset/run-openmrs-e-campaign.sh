#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
FAULT="$ROOT/scripts/fault.sh"
MODES_CSV="${MODES:-V0,T5,T10,T30,FA1}"
PROFILES_CSV="${OPENMRS_E_PROFILES:-moderate}"
RUNS="${RUNS_PER_MODE:-2}"
START="${START_RUN:-3}"
RESET="${RESET_SECONDS:-60}"
RUN_TIMEOUT="${RUN_TIMEOUT_SECONDS:-2400}"
CAMPAIGN="$ROOT/experiments/evaluation/openmrs/campaigns/e-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$CAMPAIGN"
exec > >(tee -a "$CAMPAIGN/campaign.log") 2>&1
SUMMARY="$CAMPAIGN/summary.csv"
PLAN="$CAMPAIGN/plan.csv"
printf 'profile,mode,run,status,started,finished,exit_code\n' > "$SUMMARY"
printf 'profile,mode,run\n' > "$PLAN"
fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ "$RUNS" =~ ^[0-9]+$ && "$START" =~ ^[0-9]+$ && "$RESET" =~ ^[0-9]+$ && "$RUN_TIMEOUT" =~ ^[0-9]+$ ]] || fail 'Invalid numeric setting'
(( RUNS > 0 && RUN_TIMEOUT > 0 )) || fail 'Run count and timeout must be positive'
[[ -x "$RUNNER" && -x "$FAULT" ]] || fail 'OpenMRS integrated runner or legacy fault wrapper missing/not executable'
[[ -f "$ROOT/harness/config/openmrs-scenario-e.json" ]] || fail 'OpenMRS E harness configuration missing'
[[ -f "${SSH_KEY:-$HOME/.ssh/k8s-aware}" ]] || fail 'SSH key missing'
command -v shuf >/dev/null || fail 'shuf missing'
IFS=',' read -r -a MODES_ARRAY <<< "$MODES_CSV"
IFS=',' read -r -a PROFILES_ARRAY <<< "$PROFILES_CSV"
(( ${#MODES_ARRAY[@]} > 0 && ${#PROFILES_ARRAY[@]} > 0 )) || fail 'Empty modes/profiles'
for mode in "${MODES_ARRAY[@]}"; do case "$mode" in V0|T5|T10|T30|FA1) ;; *) fail "Unsupported mode: $mode";; esac; done
for profile in "${PROFILES_ARRAY[@]}"; do case "$profile" in mild|moderate|severe) ;; *) fail "Unsupported profile: $profile";; esac; done
# The integrated E runner expects the legacy remote fault mechanism to report 'none' when cleared.
check_fault_clear(){
 local output
 output="$(timeout 25 "$FAULT" scenario-e show 2>&1)" || return 1
 grep -Eq '^none$' <<< "$output"
}
for ((i=0;i<RUNS;i++)); do
  id="$(printf '%03d' "$((10#$START+i))")"
  mapfile -t ORDER < <(printf '%s\n' "${MODES_ARRAY[@]}" | shuf)
  for mode in "${ORDER[@]}"; do
    for profile in "${PROFILES_ARRAY[@]}"; do
      result_dir="$ROOT/experiments/evaluation/openmrs/scenario-e/$profile/$mode/run-$id"
      [[ ! -e "$result_dir" ]] || fail "Existing results; refusing overwrite: $result_dir"
      printf '%s,%s,%s\n' "$profile" "$mode" "$id" >> "$PLAN"
    done
  done
done
printf 'Scenario E plan: %s\n' "$PLAN"
if [[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" != true ]]; then
  echo 'PLAN ONLY: no faults injected. Set OPENMRS_CAMPAIGN_EXECUTE=true to run.'
  exit 0
fi
[[ "${OPENMRS_ENABLE_FAULTS:-false}" == true ]] || fail 'OPENMRS_ENABLE_FAULTS=true required'
check_fault_clear || fail 'Legacy Scenario E fault status not confirmed clear'
while IFS=',' read -r profile mode id; do
  [[ "$profile" == profile ]] && continue
  result_dir="$ROOT/experiments/evaluation/openmrs/scenario-e/$profile/$mode/run-$id"
  [[ ! -e "$result_dir" ]] || fail "Existing results: $result_dir"
  check_fault_clear || fail 'Fault remains active or status unknown before run'
  start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "START scenario-e profile=$profile mode=$mode run=$id"
  rc=0
  timeout --signal=TERM --kill-after=30s "${RUN_TIMEOUT}s" \
    "$RUNNER" scenario-e "$mode" "$id" "$profile" || rc=$?
  end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  status=FAILED
  if (( rc == 0 )) && [[ -f "$result_dir/COMPLETE" ]] && [[ ! -e "$result_dir/INCOMPLETE" ]] && check_fault_clear; then
    status=OBSERVATION_COMPLETE
  fi
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$profile" "$mode" "$id" "$status" "$start_utc" "$end_utc" "$rc" >> "$SUMMARY"
  [[ "$status" == OBSERVATION_COMPLETE ]] || fail "Run failed or cleanup unverified: $profile/$mode/$id"
  sleep "$RESET"
done < "$PLAN"
echo "Campaign observations complete: $CAMPAIGN"
