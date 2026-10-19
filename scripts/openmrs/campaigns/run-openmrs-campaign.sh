#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMRS experimental campaign runner.
#
# Executes scenario-specific experimental campaigns.
#
# Usage:
#   run-openmrs-campaign.sh legacy scenario-b|scenario-c
#   run-openmrs-campaign.sh integrated scenario-c|scenario-e [profile]
#
# The original legacy invocation is also supported:
#   run-openmrs-campaign.sh scenario-b|scenario-c
#
# No experimental algorithms are modified.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

SCENARIO="${1:-}"
PROFILE="${2:-}"

case "$SCENARIO" in
    scenario-b)
        CAMPAIGN_TYPE="standard"
        ;;
    scenario-c)
        case "$PROFILE" in
            ""|standard)
                CAMPAIGN_TYPE="standard"
                ;;
            network)
                CAMPAIGN_TYPE="profiled"
                ;;
            *)
                echo "Usage: $0 scenario-c [standard|network]" >&2
                exit 2
                ;;
        esac
        ;;
    scenario-e)
        CAMPAIGN_TYPE="profiled"
        PROFILE="${PROFILE:-mild}"
        ;;
    *)
        echo "Usage:" >&2
        echo "  $0 scenario-b" >&2
        echo "  $0 scenario-c [standard|network]" >&2
        echo "  $0 scenario-e [mild|moderate|severe]" >&2
        exit 2
        ;;
esac

if [[ "$CAMPAIGN_TYPE" == "profiled" ]]; then
    set -- "$SCENARIO" "$PROFILE"
else
    set -- "$SCENARIO"
fi

case "$CAMPAIGN_TYPE" in
    standard)
        (
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
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

        )
        ;;
    profiled)
        (
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCENARIO="${1:-}"; case "$SCENARIO" in scenario-c|scenario-e) ;; *) echo 'Usage: run-openmrs-campaign-integrated.sh scenario-c|scenario-e [profile]' >&2; exit 2;; esac
PROFILE="${2:-mild}"
COUNT="${RUNS_PER_MODE:-10}"; START="${START_RUN:-1}"; MODES_STRING="${BENCHMARK_MODES:-V0 T5 T10 T30 FA1}"
[[ "$COUNT" =~ ^[0-9]+$ && "$START" =~ ^[0-9]+$ ]] || exit 2
read -r -a MODES <<< "$MODES_STRING"
CAMPAIGN="$ROOT/experiments/evaluation/openmrs/campaign-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$CAMPAIGN"; printf 'scenario,profile,mode,run,result,started,finished\n' > "$CAMPAIGN/attempts.csv"
for ((i=0;i<COUNT;i++)); do
 RUN_ID="$(printf '%03d' "$((START+i))")"
 mapfile -t ORDER < <(printf '%s\n' "${MODES[@]}" | shuf)
 for MODE in "${ORDER[@]}"; do
  STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; RESULT=FAILED
  if "$ROOT/scripts/run-openmrs-integrated.sh" "$SCENARIO" "$MODE" "$RUN_ID" "$PROFILE" > "$CAMPAIGN/${SCENARIO}-${PROFILE}-${MODE}-${RUN_ID}.log" 2>&1; then RESULT=COMPLETE; fi
  FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$SCENARIO" "$PROFILE" "$MODE" "$RUN_ID" "$RESULT" "$STARTED" "$FINISHED" >> "$CAMPAIGN/attempts.csv"
  [[ "$RESULT" == COMPLETE ]] || { echo "Stopped at $MODE/$RUN_ID; inspect $CAMPAIGN" >&2; exit 1; }
  sleep "${RESET_SECONDS:-60}"
 done
done
echo "Campaign complete: $CAMPAIGN"

        )
        ;;
esac
