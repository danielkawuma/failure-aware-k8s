#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
POD_IP="${2:-}"

API_IP="102.34.160.89"
API_PORT="6443"
BACKEND_PORT="8080"

STATE_FILE="/run/failure-aware-openmrs-fault"

fail() {
    echo "[OPENMRS FAULT] ERROR: $*" >&2
    exit 1
}

api_rule() {
    iptables "$1" OUTPUT \
        -p tcp \
        -d "$API_IP" \
        --dport "$API_PORT" \
        -j DROP
}

backend_rule() {
    iptables "$1" FORWARD \
        -p tcp \
        -d "$POD_IP" \
        --dport "$BACKEND_PORT" \
        -j DROP
}

case "$ACTION" in
    apply)
        [[ "$POD_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
            fail "Valid Pod IP required"

        [[ ! -e "$STATE_FILE" ]] ||
            fail "Existing fault must be cleared first"

        printf '%s\n' "$POD_IP" > "$STATE_FILE"

        api_rule -C 2>/dev/null ||
            api_rule -I

        backend_rule -C 2>/dev/null ||
            backend_rule -I

        echo "Scenario C fault applied"
        ;;

    status)
        [[ -f "$STATE_FILE" ]] ||
            fail "No recorded active fault"

        POD_IP="$(cat "$STATE_FILE")"

        api_rule -C ||
            fail "API fault missing"

        backend_rule -C ||
            fail "Backend fault missing"

        echo "FENCED_NETWORK_PATHS"
        ;;

    clear)
        [[ -f "$STATE_FILE" ]] ||
            fail "No recorded fault; refusing unverified cleanup"

        POD_IP="$(cat "$STATE_FILE")"

        while api_rule -C 2>/dev/null; do
            api_rule -D
        done

        while backend_rule -C 2>/dev/null; do
            backend_rule -D
        done

        rm -f "$STATE_FILE"

        echo "Scenario C fault cleared"
        ;;

    *)
        echo "Usage: $0 apply POD_IP | status | clear"
        exit 2
        ;;
esac