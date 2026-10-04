#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

REPO_ROOT="$(
    cd "${SCRIPT_DIR}/.."
    pwd
)"

COUNT="${1:-30}"
DURATION_SECONDS="${DURATION_SECONDS:-10}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
WARMUP_SECONDS="${WARMUP_SECONDS:-3}"

CONTROLLER_BINARY="${REPO_ROOT}/controller/target/debug/failure-aware-controller"
COLLECTOR="${SCRIPT_DIR}/collect-overhead.sh"
ANALYZER="${REPO_ROOT}/analysis/analyze-overhead.py"

RESULTS_DIR="${REPO_ROOT}/analysis/results"
RAW_OUTPUT="${RESULTS_DIR}/controller_overhead.csv"
RUN_OUTPUT="${RESULTS_DIR}/controller_overhead_runs.csv"
SUMMARY_OUTPUT="${RESULTS_DIR}/controller_overhead_summary.csv"
CONTROLLER_LOG="${RESULTS_DIR}/controller_overhead_controller.log"

if ! [[ "${COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Run count must be a positive integer" >&2
    exit 1
fi

for output in \
    "${RAW_OUTPUT}" \
    "${RUN_OUTPUT}" \
    "${SUMMARY_OUTPUT}" \
    "${CONTROLLER_LOG}"
do
    if [[ -e "${output}" ]]; then
        echo "Refusing to overwrite existing file:" >&2
        echo "${output}" >&2
        echo "Move or rename it before starting a new campaign." >&2
        exit 1
    fi
done

mkdir -p "${RESULTS_DIR}"

if [[ ! -x "${COLLECTOR}" ]]; then
    echo "Collector is not executable: ${COLLECTOR}" >&2
    exit 1
fi

NETWORK_INTERFACE="${NETWORK_INTERFACE:-$(
    ip route show default |
    awk 'NR == 1 {print $5}'
)}"

if [[ -z "${NETWORK_INTERFACE}" ]]; then
    echo "Could not determine the default network interface." >&2
    echo "Set NETWORK_INTERFACE explicitly." >&2
    exit 1
fi

echo "Building Failure-Aware Controller"

cargo build \
    --manifest-path "${REPO_ROOT}/controller/Cargo.toml"

if [[ ! -x "${CONTROLLER_BINARY}" ]]; then
    echo "Controller binary was not produced:" >&2
    echo "${CONTROLLER_BINARY}" >&2
    exit 1
fi

if pgrep -f -- "${CONTROLLER_BINARY}" >/dev/null; then
    echo "A Failure-Aware Controller process is already running." >&2
    echo "Stop it before starting the overhead campaign." >&2
    exit 1
fi

CONTROLLER_PID=""

stop_controller() {
    if [[ -n "${CONTROLLER_PID}" ]]; then
        kill -TERM "${CONTROLLER_PID}" 2>/dev/null || true
        wait "${CONTROLLER_PID}" 2>/dev/null || true
        CONTROLLER_PID=""
    fi
}

cleanup() {
    stop_controller
}

trap cleanup EXIT INT TERM

collect_native() {
    local run_id="$1"

    if pgrep -f -- "${CONTROLLER_BINARY}" >/dev/null; then
        echo "Controller detected during native run ${run_id}" >&2
        exit 1
    fi

    echo "Collecting native run ${run_id}"

    RUN_ID="${run_id}" \
    SCENARIO="controller-overhead" \
    MODE="native" \
    PHASE="steady-state" \
    PROCESS_PATTERN="${CONTROLLER_BINARY}" \
    EXPECT_PROCESS="absent" \
    NETWORK_INTERFACE="${NETWORK_INTERFACE}" \
    INTERVAL_SECONDS="${INTERVAL_SECONDS}" \
    DURATION_SECONDS="${DURATION_SECONDS}" \
    OUTPUT="${RAW_OUTPUT}" \
    APPEND="true" \
    "${COLLECTOR}"
}

collect_failure_aware() {
    local run_id="$1"

    echo "Starting controller for Failure-Aware run ${run_id}"

    (
        cd "${REPO_ROOT}"
        exec "${CONTROLLER_BINARY}"
    ) >> "${CONTROLLER_LOG}" 2>&1 &

    CONTROLLER_PID=$!

    sleep "${WARMUP_SECONDS}"

    if ! kill -0 "${CONTROLLER_PID}" 2>/dev/null; then
        echo "Controller failed to remain running." >&2
        echo "Inspect: ${CONTROLLER_LOG}" >&2
        exit 1
    fi

    echo "Collecting Failure-Aware run ${run_id}"

    RUN_ID="${run_id}" \
    SCENARIO="controller-overhead" \
    MODE="failure-aware" \
    PHASE="steady-state" \
    PROCESS_PATTERN="${CONTROLLER_BINARY}" \
    EXPECT_PROCESS="required" \
    NETWORK_INTERFACE="${NETWORK_INTERFACE}" \
    INTERVAL_SECONDS="${INTERVAL_SECONDS}" \
    DURATION_SECONDS="${DURATION_SECONDS}" \
    OUTPUT="${RAW_OUTPUT}" \
    APPEND="true" \
    "${COLLECTOR}"

    stop_controller
}

echo
echo "=========================================="
echo "Controller overhead campaign"
echo "Paired runs          : ${COUNT}"
echo "Observation per mode : ${DURATION_SECONDS}s"
echo "Sampling interval    : ${INTERVAL_SECONDS}s"
echo "Network interface    : ${NETWORK_INTERFACE}"
echo "=========================================="
echo

for number in $(seq 1 "${COUNT}"); do
    run_id="$(
        printf "%03d" "${number}"
    )"

    echo
    echo "Paired run ${run_id}/${COUNT}"

    # Alternate ordering to reduce systematic time-order bias.
    if (( number % 2 == 1 )); then
        collect_native "${run_id}"
        collect_failure_aware "${run_id}"
    else
        collect_failure_aware "${run_id}"
        collect_native "${run_id}"
    fi

    sleep 1
done

python3 "${ANALYZER}" \
    "${RAW_OUTPUT}" \
    --run-output "${RUN_OUTPUT}" \
    --output "${SUMMARY_OUTPUT}"

echo
echo "=========================================="
echo "OVERHEAD CAMPAIGN COMPLETE"
echo "Raw samples : ${RAW_OUTPUT}"
echo "Per-run     : ${RUN_OUTPUT}"
echo "Summary     : ${SUMMARY_OUTPUT}"
echo "Log         : ${CONTROLLER_LOG}"
echo "=========================================="