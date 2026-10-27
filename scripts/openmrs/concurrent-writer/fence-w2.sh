#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"

CHAIN="FA_WRITER_TEST"
WORKER1="102.34.160.87"
NFS_PORT="2049"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 fence|status|unfence" >&2
    exit 2
}

rule_exists() {
    iptables -C INPUT \
        -p tcp \
        -s "$WORKER1" \
        --dport "$NFS_PORT" \
        -j "$CHAIN" \
        >/dev/null 2>&1
}

chain_exists() {
    iptables -nL "$CHAIN" >/dev/null 2>&1
}

fence() {
    if ! chain_exists; then
        iptables -N "$CHAIN"
    fi

    if ! iptables -C "$CHAIN" \
        -p tcp \
        -s "$WORKER1" \
        --dport "$NFS_PORT" \
        -j DROP \
        >/dev/null 2>&1; then

        iptables -A "$CHAIN" \
            -p tcp \
            -s "$WORKER1" \
            --dport "$NFS_PORT" \
            -j DROP
    fi

    if ! rule_exists; then
        iptables -I INPUT 1 \
            -p tcp \
            -s "$WORKER1" \
            --dport "$NFS_PORT" \
            -j "$CHAIN"
    fi

    echo "W2_FENCE_RULE_INSTALLED"
}

status() {
    if chain_exists &&
       rule_exists &&
       iptables -C "$CHAIN" \
           -p tcp \
           -s "$WORKER1" \
           --dport "$NFS_PORT" \
           -j DROP \
           >/dev/null 2>&1; then

        echo "W2_FIREWALL_RULE_PRESENT"
        exit 0
    fi

    echo "W2_FIREWALL_RULE_ABSENT"
    exit 1
}

unfence() {
    if rule_exists; then
        iptables -D INPUT \
            -p tcp \
            -s "$WORKER1" \
            --dport "$NFS_PORT" \
            -j "$CHAIN"
    fi

    if chain_exists; then
        iptables -F "$CHAIN"
        iptables -X "$CHAIN"
    fi

    echo "W2_FENCE_RULE_REMOVED"
}

case "$ACTION" in
    fence)
        fence
        status
        ;;
    status)
        status
        ;;
    unfence)
        unfence
        ;;
    *)
        usage
        ;;
esac
