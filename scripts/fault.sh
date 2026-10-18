#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Failure-Aware Kubernetes Fault Orchestrator
#
# Executes the existing remote fault helper on Worker1.
#
# Supported commands:
#   scenario-b apply
#   scenario-b clear
#   scenario-c apply POD_IP
#   scenario-c clear
#   scenario-e apply PROFILE
#   scenario-e clear
#   scenario-e show
#   clear-all
#
# This script does not change the remote fault rules.
# ============================================================

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

source "${SCRIPT_DIR}/experiment-config.sh"

# ============================================================
# Timeout configuration
# ============================================================

SSH_CONNECT_TIMEOUT_SECONDS="${FAILURE_AWARE_SSH_CONNECT_TIMEOUT_SECONDS:-5}"

SSH_COMMAND_TIMEOUT_SECONDS="${FAILURE_AWARE_SSH_COMMAND_TIMEOUT_SECONDS:-30}"

SSH_CLEANUP_TIMEOUT_SECONDS="${FAILURE_AWARE_SSH_CLEANUP_TIMEOUT_SECONDS:-45}"

SSH_KEEPALIVE_INTERVAL_SECONDS="${FAILURE_AWARE_SSH_KEEPALIVE_INTERVAL_SECONDS:-5}"

SSH_KEEPALIVE_COUNT="${FAILURE_AWARE_SSH_KEEPALIVE_COUNT:-2}"

# ============================================================
# Helpers
# ============================================================

log() {
    printf '[FAULT ORCHESTRATOR] %s\n' "$*" >&2
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

valid_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

# ============================================================
# Validate configuration
# ============================================================

for value in \
    "$SSH_CONNECT_TIMEOUT_SECONDS" \
    "$SSH_COMMAND_TIMEOUT_SECONDS" \
    "$SSH_CLEANUP_TIMEOUT_SECONDS" \
    "$SSH_KEEPALIVE_INTERVAL_SECONDS" \
    "$SSH_KEEPALIVE_COUNT"
do
    valid_positive_integer "$value" ||
        fail "Invalid positive integer setting: $value"
done

[[ -f "$SSH_KEY" ]] ||
    fail "SSH private key missing: $SSH_KEY"

[[ -n "$WORKER1_SSH" ]] ||
    fail "WORKER1_SSH is not configured"

command -v ssh >/dev/null ||
    fail "ssh command unavailable"

command -v timeout >/dev/null ||
    fail "timeout command unavailable"

# ============================================================
# Validate requested fault operation
# ============================================================

SCENARIO="${1:-}"
ACTION="${2:-}"

case "$SCENARIO:$ACTION" in
    scenario-b:apply|scenario-b:clear)
        [[ $# -eq 2 ]] ||
            fail "Usage: $0 scenario-b apply|clear"
        ;;

    scenario-c:apply)
        [[ $# -eq 3 ]] ||
            fail "Usage: $0 scenario-c apply POD_IP"

        [[ "$3" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
            fail "Invalid Pod IP: $3"
        ;;

    scenario-c:clear)
        [[ $# -eq 2 ]] ||
            fail "Usage: $0 scenario-c clear"
        ;;

    scenario-e:apply)
        [[ $# -eq 3 ]] ||
            fail "Usage: $0 scenario-e apply mild|moderate|severe"

        case "$3" in
            mild|moderate|severe)
                ;;
            *)
                fail "Invalid Scenario E profile: $3"
                ;;
        esac
        ;;

    scenario-e:clear|scenario-e:show)
        [[ $# -eq 2 ]] ||
            fail "Usage: $0 scenario-e clear|show"
        ;;

    clear-all:)
        [[ $# -eq 1 ]] ||
            fail "Usage: $0 clear-all"
        ;;

    *)
        fail "Unsupported fault operation: $*"
        ;;
esac

# ============================================================
# Select remote-execution timeout
# ============================================================

COMMAND_TIMEOUT="$SSH_COMMAND_TIMEOUT_SECONDS"

case "$SCENARIO:$ACTION" in
    scenario-b:clear|scenario-c:clear|scenario-e:clear|clear-all:)
        COMMAND_TIMEOUT="$SSH_CLEANUP_TIMEOUT_SECONDS"
        ;;
esac

# ============================================================
# Execute remote fault operation
#
# The outer timeout limits the complete SSH operation.
#
# Exit 124 indicates a timeout.
# Exit 255 commonly indicates an SSH connection failure.
#
# A timeout during apply may leave a partially applied fault.
# The caller must verify and clear the fault before retrying.
# ============================================================

log "action=${ACTION:-$SCENARIO}"
log "remote=$WORKER1_SSH"
log "timeout=${COMMAND_TIMEOUT}s"

RC=0

timeout \
    --signal=TERM \
    --kill-after=5s \
    "${COMMAND_TIMEOUT}s" \
    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT_SECONDS" \
        -o "ServerAliveInterval=$SSH_KEEPALIVE_INTERVAL_SECONDS" \
        -o "ServerAliveCountMax=$SSH_KEEPALIVE_COUNT" \
        "$WORKER1_SSH" \
        sudo -n \
        /usr/local/sbin/failure-aware-fault \
        "$@" || RC=$?

if (( RC == 0 )); then
    log "action completed successfully"
    exit 0
fi

case "$RC" in
    124|137)
        fail "Remote fault operation timed out (exit=$RC). Fault state may be ambiguous; verify and clear before retrying."
        ;;

    255)
        fail "SSH connection or remote session failed (exit=$RC). Fault state may be ambiguous."
        ;;

    *)
        fail "Remote fault operation failed (exit=$RC). Inspect remote fault state before retrying."
        ;;
esac