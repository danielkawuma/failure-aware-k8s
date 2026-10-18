#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

COUNT_PER_PROFILE="${1:-10}"
START_RUN="${2:-1}"

if ! [[ "${COUNT_PER_PROFILE}" =~ ^[0-9]+$ ]] || (( COUNT_PER_PROFILE < 1 )); then
    echo "ERROR: count per profile must be a positive integer."
    exit 1
fi

if ! [[ "${START_RUN}" =~ ^[0-9]+$ ]] || (( START_RUN < 1 )); then
    echo "ERROR: starting run number must be a positive integer."
    exit 1
fi

PROFILES=(mild moderate severe)
TOTAL_RUNS=$((COUNT_PER_PROFILE * ${#PROFILES[@]}))
completed_runs=0
skipped_runs=0

echo "=========================================="
echo "Scenario E campaign"
echo "Profiles         : ${PROFILES[*]}"
echo "Runs per profile : ${COUNT_PER_PROFILE}"
echo "Starting run     : ${START_RUN}"
echo "Total runs       : ${TOTAL_RUNS}"
echo "Execution        : sequential"
echo "=========================================="

for profile in "${PROFILES[@]}"; do
    for ((offset = 0; offset < COUNT_PER_PROFILE; offset++)); do
        run_number=$((START_RUN + offset))
        formatted_run="$(printf '%03d' "${run_number}")"
        run_dir="${SCRIPT_DIR}/../experiments/evaluation/scenario-e/failure-aware/${profile}/run-${formatted_run}"

        echo
        echo "########################################"
        echo "Starting Scenario E"
        echo "Profile: ${profile}"
        echo "Run    : ${formatted_run}"
        echo "########################################"

        if [[ -f "${run_dir}/COMPLETE" ]]; then
            echo "Skipping completed ${profile}/run-${formatted_run}"
            skipped_runs=$((skipped_runs + 1))
            continue
        fi

        "${SCRIPT_DIR}/run-scenario-e.sh" \
            "${profile}" \
            "${formatted_run}"

        if [[ ! -f "${run_dir}/COMPLETE" ]]; then
            echo "ERROR: ${profile}/run-${formatted_run} returned without COMPLETE marker"
            exit 1
        fi

        completed_runs=$((completed_runs + 1))

        echo
        echo "Completed ${profile}/run-${formatted_run}"
        echo "Campaign progress: $((completed_runs + skipped_runs))/${TOTAL_RUNS}"

        sleep 5
    done
done

echo
echo "=========================================="
echo "SCENARIO E CAMPAIGN COMPLETE"
echo "Completed now : ${completed_runs}"
echo "Skipped       : ${skipped_runs}"
echo "Total covered : $((completed_runs + skipped_runs))/${TOTAL_RUNS}"
echo "=========================================="
