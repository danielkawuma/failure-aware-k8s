#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

RUNS="${1:-}"

if [[ -z "${RUNS}" ]]; then
    echo "Usage:"
    echo "  $0 <number-of-runs>"
    echo
    echo "Example:"
    echo "  $0 10"
    exit 1
fi

echo "=================================================="
echo "Scenario D Stateful Fencing Campaign"
echo "Runs requested: ${RUNS}"
echo "=================================================="

for ((i=1; i<=RUNS; i++))
do
    RUN_NUMBER="$(
        printf "%03d" "${i}"
    )"

    echo
    echo "--------------------------------------------------"
    echo "Scenario D run ${RUN_NUMBER}"
    echo "--------------------------------------------------"

    "${SCRIPT_DIR}/run-scenario-d.sh" \
        "${RUN_NUMBER}"

    echo
    echo "Run ${RUN_NUMBER} complete."

    sleep 5
done

echo
echo "=================================================="
echo "SCENARIO D CAMPAIGN COMPLETE"
echo "=================================================="