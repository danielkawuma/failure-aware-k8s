#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

COUNT_PER_PROFILE="${1:-10}"
START_RUN="${2:-1}"

if ! [[ "${COUNT_PER_PROFILE}" =~ ^[0-9]+$ ]] ||
   (( COUNT_PER_PROFILE < 1 ))
then
    echo "ERROR: count per profile must be a positive integer."
    exit 1
fi

if ! [[ "${START_RUN}" =~ ^[0-9]+$ ]] ||
   (( START_RUN < 1 ))
then
    echo "ERROR: starting run number must be a positive integer."
    exit 1
fi

PROFILES=(
    mild
    moderate
    severe
)

TOTAL_RUNS=$((
    COUNT_PER_PROFILE * ${#PROFILES[@]}
))

completed_runs=0

echo "=========================================="
echo "Scenario E campaign"
echo "Profiles         : ${PROFILES[*]}"
echo "Runs per profile : ${COUNT_PER_PROFILE}"
echo "Total runs       : ${TOTAL_RUNS}"
echo "Execution        : sequential"
echo "=========================================="

for profile in "${PROFILES[@]}"; do
    for ((offset = 0; offset < COUNT_PER_PROFILE; offset++)); do
        run_number=$((START_RUN + offset))

        formatted_run="$(
            printf '%03d' "${run_number}"
        )"

        echo
        echo "########################################"
        echo "Starting Scenario E"
        echo "Profile: ${profile}"
        echo "Run    : ${formatted_run}"
        echo "########################################"

        "${SCRIPT_DIR}/run-scenario-e.sh" \
          "${profile}" \
          "${formatted_run}"

        completed_runs=$((completed_runs + 1))

        echo
        echo "Completed ${profile}/run-${formatted_run}"
        echo "Campaign progress: ${completed_runs}/${TOTAL_RUNS}"

        sleep 5
    done
done

echo
echo "=========================================="
echo "SCENARIO E CAMPAIGN COMPLETE"
echo "Completed runs: ${completed_runs}/${TOTAL_RUNS}"
echo "=========================================="