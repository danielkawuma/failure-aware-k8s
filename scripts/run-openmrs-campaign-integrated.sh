#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
