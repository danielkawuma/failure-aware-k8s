#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || die "usage: $0 <run-result-dir>"

mkdir -p "$RUN_DIR"
rm -f "$RUN_DIR/COMPLETE" "$RUN_DIR/FAILED"

preflight

SUITE_START="$(timestamp)"
echo "$SUITE_START" > "$RUN_DIR/started_at.txt"

tests=(reliability resource availability recover)

for test in "${tests[@]}"; do
  echo
  echo "============================================================"
  echo "Running candidate-selection test: $test"
  echo "============================================================"
  "$SCRIPT_DIR/run-test.sh" "$test" "$RUN_DIR/$test"
done

restore_baseline
snapshot "$RUN_DIR/final-cluster-state.txt"

{
  echo "started_at=$SUITE_START"
  echo "completed_at=$(timestamp)"
  echo "tests=${tests[*]}"
  echo "status=PASS"
} > "$RUN_DIR/result.env"

touch "$RUN_DIR/COMPLETE"
echo
echo "Candidate-selection suite PASS"
echo "Results: $RUN_DIR"
