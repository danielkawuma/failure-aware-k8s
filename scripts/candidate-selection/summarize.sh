#!/usr/bin/env bash
set -euo pipefail

CAMPAIGN_DIR="${1:-}"
[[ -n "$CAMPAIGN_DIR" ]] || {
  echo "usage: $0 <campaign-result-dir>" >&2
  exit 1
}

printf '%-10s %-14s %-18s %-10s\n' "RUN" "TEST" "SELECTED/PLACED" "STATUS"
printf '%-10s %-14s %-18s %-10s\n' "----------" "--------------" "------------------" "----------"

for run_dir in "$CAMPAIGN_DIR"/run-*; do
  [[ -d "$run_dir" ]] || continue
  run="$(basename "$run_dir")"

  for test in reliability resource availability recover; do
    test_dir="$run_dir/$test"
    status="FAIL"
    [[ -f "$test_dir/COMPLETE" ]] && status="PASS"

    selected="-"
    if [[ -f "$test_dir/controller.log" ]]; then
      selected="$(sed -n 's/.*\[SELECTION\] selected=\([^ ]*\).*/\1/p' "$test_dir/controller.log" | tail -n 1)"
      [[ -n "$selected" ]] || selected="-"
    fi

    if [[ "$test" == "recover" && -f "$test_dir/replacement_node.txt" ]]; then
      selected="$(cat "$test_dir/replacement_node.txt")"
    fi

    printf '%-10s %-14s %-18s %-10s\n' "$run" "$test" "$selected" "$status"
  done
done
