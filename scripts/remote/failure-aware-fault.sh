#!/usr/bin/env bash

set -euo pipefail

API_SERVER_IP="102.34.160.89"
API_SERVER_PORT="6443"

STATE_FILE="/run/failure-aware-fault-pod-ip"

add_api_fault() {
    if ! /usr/sbin/iptables -C OUTPUT \
        -p tcp \
        -d "${API_SERVER_IP}" \
        --dport "${API_SERVER_PORT}" \
        -j DROP \
        2>/dev/null
    then
        /usr/sbin/iptables -I OUTPUT 1 \
            -p tcp \
            -d "${API_SERVER_IP}" \
            --dport "${API_SERVER_PORT}" \
            -j DROP
    fi
}

clear_api_fault() {
    while /usr/sbin/iptables -C OUTPUT \
        -p tcp \
        -d "${API_SERVER_IP}" \
        --dport "${API_SERVER_PORT}" \
        -j DROP \
        2>/dev/null
    do
        /usr/sbin/iptables -D OUTPUT \
            -p tcp \
            -d "${API_SERVER_IP}" \
            --dport "${API_SERVER_PORT}" \
            -j DROP
    done
}

add_workload_fault() {
    local pod_ip="$1"

    if ! /usr/sbin/iptables -C FORWARD \
        -p tcp \
        -d "${pod_ip}" \
        --dport 80 \
        -j DROP \
        2>/dev/null
    then
        /usr/sbin/iptables -I FORWARD 1 \
            -p tcp \
            -d "${pod_ip}" \
            --dport 80 \
            -j DROP
    fi

    printf '%s\n' \
        "${pod_ip}" \
        > "${STATE_FILE}"
}

clear_workload_fault() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        return 0
    fi

    local pod_ip

    pod_ip="$(
        cat "${STATE_FILE}"
    )"

    while /usr/sbin/iptables -C FORWARD \
        -p tcp \
        -d "${pod_ip}" \
        --dport 80 \
        -j DROP \
        2>/dev/null
    do
        /usr/sbin/iptables -D FORWARD \
            -p tcp \
            -d "${pod_ip}" \
            --dport 80 \
            -j DROP
    done

    rm -f "${STATE_FILE}"
}

usage() {
    echo "Usage:"
    echo "  failure-aware-fault scenario-b apply"
    echo "  failure-aware-fault scenario-b clear"
    echo "  failure-aware-fault scenario-c apply POD_IP"
    echo "  failure-aware-fault scenario-c clear"
    echo "  failure-aware-fault clear-all"
    exit 1
}

scenario="${1:-}"
action="${2:-}"
pod_ip="${3:-}"

case "${scenario}:${action}" in

    scenario-b:apply)
        add_api_fault
        ;;

    scenario-b:clear)
        clear_api_fault
        ;;

    scenario-c:apply)
        if [[ -z "${pod_ip}" ]]; then
            usage
        fi

        add_workload_fault "${pod_ip}"
        add_api_fault
        ;;

    scenario-c:clear)
        clear_workload_fault
        clear_api_fault
        ;;

    clear-all:)
        clear_workload_fault
        clear_api_fault
        ;;

    *)
        usage
        ;;
esac