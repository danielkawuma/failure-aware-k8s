#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCENARIO=${1:?Usage: run-openmrs-campaign.sh scenario-b|scenario-c}
case "$SCENARIO" in scenario-b|scenario-c) ;; *) exit 2;; esac
[[ ${OPENMRS_CAMPAIGN_APPROVED:-false} == true ]] || {
 echo 'Pilot approval required: OPENMRS_CAMPAIGN_APPROVED=true' >&2; exit 1;
}
MODES=(V0 T5 T10 T30 FA1)
RUNS_PER_MODE=${RUNS_PER_MODE:-10}
START_RUN=${START_RUN:-1}
[[ "$RUNS_PER_MODE" =~ ^[0-9]+$ && "$START_RUN" =~ ^[0-9]+$ ]] || exit 2
((RUNS_PER_MODE>0)) || exit 2
CAMPAIGN_DIR="$ROOT/experiments/evaluation/openmrs/campaign-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$CAMPAIGN_DIR"
SUMMARY="$CAMPAIGN_DIR/summary.csv"
printf 'scenario,mode,run,status,start,end\n' > "$SUMMARY"
export SSH_KEY=${SSH_KEY:-$HOME/.ssh/k8s-aware}
export OPENMRS_ENABLE_FAULTS=true
for ((i=0;i<RUNS_PER_MODE;i++)); do
  run_id=$(printf '%03d' "$((START_RUN+i))")
  mapfile -t shuffled < <(printf '%s\n' "${MODES[@]}" | shuf)
  for mode in "${shuffled[@]}"; do
    dir="$ROOT/experiments/evaluation/openmrs/$SCENARIO/$mode/run-$run_id"
    [[ ! -e "$dir" ]] || { echo "Refusing overwrite: $dir" >&2; exit 1; }
    start=$(date -u +%FT%TZ)
    if "$ROOT/scripts/run-openmrs-experiment.sh" "$SCENARIO" "$mode" "$run_id"; then
      rc=0
    else rc=$?; fi
    end=$(date -u +%FT%TZ)
    status=FAILED
    if ((rc==0)) && [[ -f "$dir/COMPLETE" && ! -f "$dir/INCOMPLETE" ]]; then status=COMPLETE; fi
    printf '%s,%s,%s,%s,%s,%s\n' "$SCENARIO" "$mode" "$run_id" "$status" "$start" "$end" >> "$SUMMARY"
    [[ "$status" == COMPLETE ]] || { echo "Campaign halted: $dir" >&2; exit 1; }
    sleep "${RESET_SECONDS:-45}"
  done
done
