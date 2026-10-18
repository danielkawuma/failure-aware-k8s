#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage:"
    echo "  $0 scenario-b native 30 [start-run]"
    echo "  $0 scenario-b failure-aware 30 [start-run]"
    echo "  $0 scenario-c native 30 [start-run]"
    echo "  $0 scenario-c failure-aware 30 [start-run]"
    exit 1
fi

SCENARIO="$1"
MODE="$2"
COUNT="$3"
START_RUN="${4:-1}"

if [[ "${SCENARIO}" != "scenario-b" &&
      "${SCENARIO}" != "scenario-c" ]]; then
    echo "Invalid scenario: ${SCENARIO}"
    exit 1
fi

if [[ "${MODE}" != "native" &&
      "${MODE}" != "failure-aware" ]]; then
    echo "Invalid mode: ${MODE}"
    exit 1
fi

if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || (( COUNT < 1 )); then
    echo "Run count must be a positive integer"
    exit 1
fi

if ! [[ "${START_RUN}" =~ ^[0-9]+$ ]] || (( START_RUN < 1 )); then
    echo "Start run must be a positive integer"
    exit 1
fi

END_RUN=$((START_RUN + COUNT - 1))
completed=0
skipped=0

for ((number = START_RUN; number <= END_RUN; number++)); do
    run="$(printf '%03d' "${number}")"
    run_dir="${SCRIPT_DIR}/../experiments/evaluation/${SCENARIO}/${MODE}/run-${run}"

    echo
    echo "########################################"
    echo "Starting ${SCENARIO}/${MODE}/run-${run}"
    echo "########################################"
    echo

    if [[ -f "${run_dir}/COMPLETE" ]]; then
        echo "Skipping completed run-${run}"
        skipped=$((skipped + 1))
        continue
    fi

    "${SCRIPT_DIR}/run-experiment.sh" \
        "${SCENARIO}" \
        "${MODE}" \
        "${run}"

    if [[ ! -f "${run_dir}/COMPLETE" ]]; then
        echo "ERROR: run-${run} returned without COMPLETE marker"
        exit 1
    fi

    completed=$((completed + 1))

    echo
    echo "Completed run-${run}"
    echo

    sleep 10
done

echo
echo "=========================================="
echo "CAMPAIGN COMPLETE"
echo "${SCENARIO}/${MODE}"
echo "Requested runs : ${COUNT}"
echo "Completed now  : ${completed}"
echo "Skipped        : ${skipped}"
echo "Run range      : ${START_RUN}-${END_RUN}"
echo "=========================================="
