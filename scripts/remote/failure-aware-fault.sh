#!/usr/bin/env bash

set -euo pipefail

API_SERVER_IP="102.34.160.89"
API_SERVER_PORT="6443"

NETWORK_INTERFACE="ens3"

WORKLOAD_STATE_FILE="/run/failure-aware-fault-pod-ip"
NETEM_STATE_FILE="/run/failure-aware-netem-profile"

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
        > "${WORKLOAD_STATE_FILE}"
}

clear_workload_fault() {
    if [[ ! -f "${WORKLOAD_STATE_FILE}" ]]; then
        return 0
    fi

    local pod_ip

    pod_ip="$(
        cat "${WORKLOAD_STATE_FILE}"
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

    rm -f "${WORKLOAD_STATE_FILE}"
}

clear_network_degradation() {
    /usr/sbin/tc qdisc del \
      dev "${NETWORK_INTERFACE}" \
      root \
      2>/dev/null \
      || true

    /usr/sbin/tc qdisc replace \
      dev "${NETWORK_INTERFACE}" \
      root \
      fq_codel

    rm -f "${NETEM_STATE_FILE}"
}

apply_network_degradation() {
    local profile="$1"
    local delay=""
    local jitter=""
    local loss=""
    local rate=""

    case "${profile}" in
        mild)
            delay="50ms"
            jitter="10ms"
            loss="1%"
            rate="10mbit"
            ;;

        moderate)
            delay="150ms"
            jitter="30ms"
            loss="3%"
            rate="5mbit"
            ;;

        severe)
            delay="300ms"
            jitter="75ms"
            loss="90%"
            rate="1mbit"
            ;;

        *)
            echo "Unknown network-degradation profile: ${profile}"
            exit 1
            ;;
    esac

    clear_network_degradation

    /usr/sbin/tc qdisc replace \
      dev "${NETWORK_INTERFACE}" \
      root \
      handle 1: \
      prio \
      bands 3

    /usr/sbin/tc qdisc replace \
      dev "${NETWORK_INTERFACE}" \
      parent 1:3 \
      handle 30: \
      netem \
      delay "${delay}" "${jitter}" \
      distribution normal \
      loss "${loss}" \
      rate "${rate}"

    /usr/sbin/tc filter replace \
      dev "${NETWORK_INTERFACE}" \
      protocol ip \
      parent 1:0 \
      priority 1 \
      u32 \
      match ip dst "${API_SERVER_IP}/32" \
      match ip protocol 6 0xff \
      match ip dport "${API_SERVER_PORT}" 0xffff \
      flowid 1:3

    printf '%s\n' \
      "${profile}" \
      > "${NETEM_STATE_FILE}"

    echo "Applied ${profile} API-server network degradation"
    echo "Delay : ${delay}"
    echo "Jitter: ${jitter}"
    echo "Loss  : ${loss}"
    echo "Rate  : ${rate}"
}

show_network_degradation() {
    echo "Active profile:"

    if [[ -f "${NETEM_STATE_FILE}" ]]; then
        cat "${NETEM_STATE_FILE}"
    else
        echo "none"
    fi

    echo
    echo "Queueing disciplines:"

    /usr/sbin/tc -s qdisc show \
      dev "${NETWORK_INTERFACE}"

    echo
    echo "Traffic-control filters:"

    /usr/sbin/tc -s filter show \
      dev "${NETWORK_INTERFACE}" \
      parent 1:0 \
      2>/dev/null \
      || true
}

usage() {
    echo "Usage:"
    echo "  failure-aware-fault scenario-b apply"
    echo "  failure-aware-fault scenario-b clear"
    echo "  failure-aware-fault scenario-c apply POD_IP"
    echo "  failure-aware-fault scenario-c clear"
    echo "  failure-aware-fault scenario-e apply PROFILE"
    echo "  failure-aware-fault scenario-e clear"
    echo "  failure-aware-fault scenario-e show"
    echo "  failure-aware-fault clear-all"
    exit 1
}

scenario="${1:-}"
action="${2:-}"
argument="${3:-}"

case "${scenario}:${action}" in
    scenario-b:apply)
        add_api_fault
        ;;

    scenario-b:clear)
        clear_api_fault
        ;;

    scenario-c:apply)
        if [[ -z "${argument}" ]]; then
            usage
        fi

        add_workload_fault "${argument}"
        add_api_fault
        ;;

    scenario-c:clear)
        clear_workload_fault
        clear_api_fault
        ;;

    scenario-e:apply)
        if [[ -z "${argument}" ]]; then
            usage
        fi

        apply_network_degradation "${argument}"
        ;;

    scenario-e:clear)
        clear_network_degradation
        ;;

    scenario-e:show)
        show_network_degradation
        ;;

    clear-all:)
        clear_workload_fault
        clear_api_fault
        clear_network_degradation
        ;;

    *)
        usage
        ;;
esac