#!/usr/bin/env bash
set -euo pipefail

: "${RUN_ID:?Set RUN_ID}"
: "${MODE:?Set MODE}"
: "${PROCESS_PATTERN:?Set PROCESS_PATTERN}"
: "${NETWORK_INTERFACE:?Set NETWORK_INTERFACE}"
: "${OUTPUT:?Set OUTPUT}"

SCENARIO="${SCENARIO:-controller-overhead}"
PHASE="${PHASE:-steady-state}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
DURATION_SECONDS="${DURATION_SECONDS:-10}"
EXPECT_PROCESS="${EXPECT_PROCESS:-required}"
APPEND="${APPEND:-false}"

if [[ "${MODE}" != "native" &&
      "${MODE}" != "failure-aware" ]]; then
    echo "Invalid mode: ${MODE}" >&2
    exit 1
fi

if [[ "${EXPECT_PROCESS}" != "required" &&
      "${EXPECT_PROCESS}" != "absent" ]]; then
    echo "EXPECT_PROCESS must be required or absent" >&2
    exit 1
fi

if [[ ! -d "/sys/class/net/${NETWORK_INTERFACE}" ]]; then
    echo "Network interface not found: ${NETWORK_INTERFACE}" >&2
    exit 1
fi

mkdir -p "$(dirname "${OUTPUT}")"

if [[ -e "${OUTPUT}" && "${APPEND}" != "true" ]]; then
    echo "Refusing to overwrite existing result: ${OUTPUT}" >&2
    exit 1
fi

if [[ ! -e "${OUTPUT}" ]]; then
    printf '%s\n' \
'timestamp,run_id,scenario,mode,phase,pid,cpu_millicores,rss_mib,network_interface,rx_bytes,tx_bytes' \
    > "${OUTPUT}"
fi

clock_ticks="$(getconf CLK_TCK)"

previous_pid=""
previous_process_ticks=""
previous_timestamp_ns=""

started="${SECONDS}"

while (( SECONDS - started < DURATION_SECONDS )); do
    timestamp="$(date --utc +%Y-%m-%dT%H:%M:%S.%NZ)"
    timestamp_ns="$(date +%s%N)"

    pid="$(
        pgrep -f -- "${PROCESS_PATTERN}" |
        head -n 1 || true
    )"

    if [[ "${EXPECT_PROCESS}" == "required" && -z "${pid}" ]]; then
        echo "Controller process disappeared during ${MODE}/${RUN_ID}" >&2
        exit 1
    fi

    if [[ "${EXPECT_PROCESS}" == "absent" && -n "${pid}" ]]; then
        echo "Controller process found during native measurement: ${pid}" >&2
        exit 1
    fi

    cpu_millicores="0"
    rss_mib="0"

    if [[ -n "${pid}" && -r "/proc/${pid}/stat" ]]; then
        process_ticks="$(
            awk '{print $14 + $15}' "/proc/${pid}/stat"
        )"

        rss_kib="$(
            awk '
                $1 == "VmRSS:" {
                    print $2
                    found = 1
                }
                END {
                    if (!found) print 0
                }
            ' "/proc/${pid}/status"
        )"

        rss_mib="$(
            awk -v kib="${rss_kib}" \
                'BEGIN {printf "%.6f", kib / 1024}'
        )"

        if [[ "${pid}" == "${previous_pid}" &&
              -n "${previous_process_ticks}" &&
              -n "${previous_timestamp_ns}" ]]; then

            delta_ticks=$((process_ticks - previous_process_ticks))
            delta_ns=$((timestamp_ns - previous_timestamp_ns))

            cpu_millicores="$(
                awk \
                    -v ticks="${delta_ticks}" \
                    -v hz="${clock_ticks}" \
                    -v ns="${delta_ns}" \
                    '
                    BEGIN {
                        if (ns <= 0) {
                            printf "0.000000"
                        } else {
                            elapsed_seconds = ns / 1000000000
                            cpu_seconds = ticks / hz
                            printf "%.6f",
                                (cpu_seconds / elapsed_seconds) * 1000
                        }
                    }
                    '
            )"
        fi

        previous_pid="${pid}"
        previous_process_ticks="${process_ticks}"
        previous_timestamp_ns="${timestamp_ns}"
    else
        pid=""
        previous_pid=""
        previous_process_ticks=""
        previous_timestamp_ns=""
    fi

    rx_bytes="$(
        cat "/sys/class/net/${NETWORK_INTERFACE}/statistics/rx_bytes"
    )"

    tx_bytes="$(
        cat "/sys/class/net/${NETWORK_INTERFACE}/statistics/tx_bytes"
    )"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${timestamp}" \
        "${RUN_ID}" \
        "${SCENARIO}" \
        "${MODE}" \
        "${PHASE}" \
        "${pid}" \
        "${cpu_millicores}" \
        "${rss_mib}" \
        "${NETWORK_INTERFACE}" \
        "${rx_bytes}" \
        "${tx_bytes}" \
        >> "${OUTPUT}"

    sleep "${INTERVAL_SECONDS}"
done