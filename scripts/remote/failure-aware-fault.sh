#!/usr/bin/env bash
set -Eeuo pipefail

API_SERVER_IP="102.34.160.89"
API_SERVER_PORT="6443"
NETWORK_INTERFACE="ens3"
WORKLOAD_STATE_FILE="/run/failure-aware-fault-pod-ip"
NETEM_STATE_FILE="/run/failure-aware-netem-profile"
TC="/usr/sbin/tc"
IPT="/usr/sbin/iptables"

add_api_fault() {
    if ! "$IPT" -C OUTPUT -p tcp -d "$API_SERVER_IP" --dport "$API_SERVER_PORT" -j DROP 2>/dev/null; then
        "$IPT" -I OUTPUT 1 -p tcp -d "$API_SERVER_IP" --dport "$API_SERVER_PORT" -j DROP
    fi
}

clear_api_fault() {
    while "$IPT" -C OUTPUT -p tcp -d "$API_SERVER_IP" --dport "$API_SERVER_PORT" -j DROP 2>/dev/null; do
        "$IPT" -D OUTPUT -p tcp -d "$API_SERVER_IP" --dport "$API_SERVER_PORT" -j DROP
    done
}

add_workload_fault() {
    local pod_ip="$1"
    [[ "$pod_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid Pod IP' >&2; return 2; }
    if ! "$IPT" -C FORWARD -p tcp -d "$pod_ip" --dport 80 -j DROP 2>/dev/null; then
        "$IPT" -I FORWARD 1 -p tcp -d "$pod_ip" --dport 80 -j DROP
    fi
    printf '%s\n' "$pod_ip" > "$WORKLOAD_STATE_FILE"
}

clear_workload_fault() {
    [[ -f "$WORKLOAD_STATE_FILE" ]] || return 0
    local pod_ip
    pod_ip="$(cat "$WORKLOAD_STATE_FILE")"
    while "$IPT" -C FORWARD -p tcp -d "$pod_ip" --dport 80 -j DROP 2>/dev/null; do
        "$IPT" -D FORWARD -p tcp -d "$pod_ip" --dport 80 -j DROP
    done
    rm -f "$WORKLOAD_STATE_FILE"
}

clear_network_degradation() {
    "$TC" qdisc del dev "$NETWORK_INTERFACE" root 2>/dev/null || true
    "$TC" qdisc replace dev "$NETWORK_INTERFACE" root fq_codel
    rm -f "$NETEM_STATE_FILE"
}

verify_network_degradation() {
    local qdisc filters
    qdisc="$("$TC" qdisc show dev "$NETWORK_INTERFACE")" || return 1
    filters="$("$TC" filter show dev "$NETWORK_INTERFACE" parent 1:0)" || return 1
    grep -Eq 'qdisc prio 1:' <<< "$qdisc" || return 1
    grep -Eq 'qdisc netem 30:' <<< "$qdisc" || return 1
    grep -Eq 'flowid 1:3' <<< "$filters" || return 1
    grep -Eq 'flowid 1:1' <<< "$filters" || return 1
}

apply_network_degradation() {
    local profile="$1" delay jitter loss rate
    case "$profile" in
        mild) delay=50ms; jitter=10ms; loss='1%'; rate=10mbit ;;
        moderate) delay=150ms; jitter=30ms; loss='3%'; rate=5mbit ;;
        severe) delay=300ms; jitter=75ms; loss='90%'; rate=1mbit ;;
        *) echo "Unknown network-degradation profile: $profile" >&2; return 2 ;;
    esac

    clear_network_degradation

    # Establish the priority root before activating impairment.
    "$TC" qdisc replace dev "$NETWORK_INTERFACE" root handle 1: prio bands 3

    # Explicitly route SSH server replies to an unaffected band.
    "$TC" filter replace dev "$NETWORK_INTERFACE" protocol ip \
        parent 1:0 priority 2 u32 \
        match ip protocol 6 0xff \
        match ip sport 22 0xffff \
        flowid 1:1

    # Route only Kubernetes API-server traffic to the impaired band.
    "$TC" filter replace dev "$NETWORK_INTERFACE" protocol ip \
        parent 1:0 priority 1 u32 \
        match ip dst "$API_SERVER_IP/32" \
        match ip protocol 6 0xff \
        match ip dport "$API_SERVER_PORT" 0xffff \
        flowid 1:3

    # Attach netem after both traffic classifiers exist.
    "$TC" qdisc replace dev "$NETWORK_INTERFACE" parent 1:3 \
        handle 30: netem delay "$delay" "$jitter" \
        distribution normal loss "$loss" rate "$rate"

    if ! verify_network_degradation; then
        echo 'ERROR: Scenario E traffic-control verification failed' >&2
        clear_network_degradation || true
        return 1
    fi

    printf '%s\n' "$profile" > "$NETEM_STATE_FILE"
    echo "Applied $profile API-server network degradation"
    echo "Delay : $delay"
    echo "Jitter: $jitter"
    echo "Loss  : $loss"
    echo "Rate  : $rate"
    echo 'Scope : outgoing API-server TCP/6443; SSH replies explicitly bypass netem'
}

show_network_degradation() {
    echo 'Active profile:'
    if [[ -f "$NETEM_STATE_FILE" ]]; then
        cat "$NETEM_STATE_FILE"
    else
        echo none
    fi
    echo
    echo 'Queueing disciplines:'
    "$TC" -s qdisc show dev "$NETWORK_INTERFACE"
    echo
    echo 'Traffic-control filters:'
    "$TC" -s filter show dev "$NETWORK_INTERFACE" parent 1:0 2>/dev/null || true
}

usage() {
    echo 'Usage:' >&2
    echo '  failure-aware-fault scenario-b apply|clear' >&2
    echo '  failure-aware-fault scenario-c apply POD_IP|clear' >&2
    echo '  failure-aware-fault scenario-e apply mild|moderate|severe' >&2
    echo '  failure-aware-fault scenario-e clear|show' >&2
    echo '  failure-aware-fault clear-all' >&2
    exit 2
}

scenario="${1:-}"
action="${2:-}"
argument="${3:-}"
case "$scenario:$action" in
    scenario-b:apply) [[ $# -eq 2 ]] || usage; add_api_fault ;;
    scenario-b:clear) [[ $# -eq 2 ]] || usage; clear_api_fault ;;
    scenario-c:apply) [[ $# -eq 3 ]] || usage; add_workload_fault "$argument"; add_api_fault ;;
    scenario-c:clear) [[ $# -eq 2 ]] || usage; clear_workload_fault; clear_api_fault ;;
    scenario-e:apply) [[ $# -eq 3 ]] || usage; apply_network_degradation "$argument" ;;
    scenario-e:clear) [[ $# -eq 2 ]] || usage; clear_network_degradation ;;
    scenario-e:show) [[ $# -eq 2 ]] || usage; show_network_degradation ;;
    clear-all:) [[ $# -eq 1 ]] || usage; clear_workload_fault; clear_api_fault; clear_network_degradation ;;
    *) usage ;;
esac