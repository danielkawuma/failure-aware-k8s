#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

RUNS="${1:-${RUNS:-1}}"
CAMPAIGN_ID="${CAMPAIGN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
CAMPAIGN_DIR="${CAMPAIGN_DIR:-$REPO_ROOT/results/candidate-selection/campaign-$CAMPAIGN_ID}"

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die "RUNS must be a positive integer"

mkdir -p "$CAMPAIGN_DIR"
rm -f "$CAMPAIGN_DIR/COMPLETE" "$CAMPAIGN_DIR/FAILED"

{
  echo "campaign_id=$CAMPAIGN_ID"
  echo "runs=$RUNS"
  echo "started_at=$(timestamp)"
  echo "repo_root=$REPO_ROOT"
  echo "controller_binary=$CONTROLLER_BIN"
  echo "fault_node=$FAULT_NODE"
  echo "candidates=$CANDIDATE_1,$CANDIDATE_2,$CANDIDATE_3"
} > "$CAMPAIGN_DIR/metadata.env"

overall_rc=0

for i in $(seq 1 "$RUNS"); do
  run_name="$(printf 'run-%03d' "$i")"
  run_dir="$CAMPAIGN_DIR/$run_name"

  if [[ -f "$run_dir/COMPLETE" ]]; then
    echo "Skipping completed $run_name"
    continue
  fi

  echo
  echo "################################################################"
  echo "Candidate-selection campaign $CAMPAIGN_ID - $run_name/$RUNS"
  echo "################################################################"

  if ! "$SCRIPT_DIR/run-suite.sh" "$run_dir"; then
    overall_rc=1
    echo "Run failed: $run_name" >&2
    break
  fi
done

restore_baseline || true

if (( overall_rc == 0 )); then
  completed="$(find "$CAMPAIGN_DIR" -mindepth 2 -maxdepth 2 -name COMPLETE -type f | wc -l | tr -d ' ')"
  {
    echo "completed_at=$(timestamp)"
    echo "requested_runs=$RUNS"
    echo "completed_runs=$completed"
    echo "status=PASS"
  } > "$CAMPAIGN_DIR/summary.env"
  touch "$CAMPAIGN_DIR/COMPLETE"
  echo
  echo "CAMPAIGN PASS: $CAMPAIGN_DIR"
else
  {
    echo "failed_at=$(timestamp)"
    echo "status=FAIL"
  } > "$CAMPAIGN_DIR/summary.env"
  touch "$CAMPAIGN_DIR/FAILED"
  echo "CAMPAIGN FAILED: $CAMPAIGN_DIR" >&2
  exit 1
fi
