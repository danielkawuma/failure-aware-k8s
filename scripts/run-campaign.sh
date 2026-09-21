#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

if [[ $# -ne 3 ]]; then
    echo "Usage:"
    echo "  $0 scenario-b failure-aware 30"
    echo "  $0 scenario-b native 30"
    echo "  $0 scenario-c failure-aware 30"
    echo "  $0 scenario-c native 30"
    exit 1
fi

SCENARIO="$1"
MODE="$2"
COUNT="$3"

if [[ "${SCENARIO}" != "scenario-b" &&
      "${SCENARIO}" != "scenario-c" ]]
then
    echo "Invalid scenario: ${SCENARIO}"
    exit 1
fi

if [[ "${MODE}" != "native" &&
      "${MODE}" != "failure-aware" ]]
then
    echo "Invalid mode: ${MODE}"
    exit 1
fi

if ! [[ "${COUNT}" =~ ^[0-9]+$ ]]; then
    echo "Run count must be an integer"
    exit 1
fi

for number in $(seq 1 "${COUNT}"); do

    run="$(
        printf "%03d" \
          "${number}"
    )"

    echo
    echo "########################################"
    echo "Starting ${SCENARIO}/${MODE}/run-${run}"
    echo "########################################"
    echo

    "${SCRIPT_DIR}/run-experiment.sh" \
      "${SCENARIO}" \
      "${MODE}" \
      "${run}"

    echo
    echo "Completed run-${run}"
    echo

    sleep 10
done

echo
echo "=========================================="
echo "CAMPAIGN COMPLETE"
echo "${SCENARIO}/${MODE}"
echo "Runs requested: ${COUNT}"
echo "=========================================="