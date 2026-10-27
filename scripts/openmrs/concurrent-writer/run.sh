#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE="$ROOT/experiments/evaluation/openmrs/concurrent-writer"

MODE="${1:-}"
RUN_ID="${2:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

case "$MODE" in
    unfenced|fenced) ;;
    *)
        echo "Usage: $0 unfenced|fenced RUN_ID" >&2
        exit 2
        ;;
esac

[[ "$RUN_ID" =~ ^[0-9]{3}$ ]] ||
    fail "RUN_ID must contain three digits"

RUN="$BASE/$MODE/run-$RUN_ID"

[[ ! -e "$RUN" ]] ||
    fail "Run directory already exists: $RUN"

# No experimental execution until the independently
# managed NFS endpoint and disposable database servers
# have been verified.

"$SCRIPT_DIR/prepare.sh"

[[ "${WRITER_TEST_EXECUTION_APPROVED:-false}" == true ]] ||
    fail "Explicit experiment approval required"

[[ "${WRITER_TEST_ENDPOINT_VERIFIED:-false}" == true ]] ||
    fail "Independent NFS endpoint verification required"

[[ "${WRITER_TEST_DATABASES_VERIFIED:-false}" == true ]] ||
    fail "Disposable database verification required"

# Commands must be configured as executable paths,
# not shell strings. No eval or shell interpretation.
for variable in \
    WRITER_TEST_START_ORIGINAL \
    WRITER_TEST_START_REPLACEMENT \
    WRITER_TEST_STOP_ALL \
    WRITER_TEST_COLLECT
do
    value="${!variable:-}"

    [[ -n "$value" && -x "$value" ]] ||
        fail "$variable must reference an executable"
done

if [[ "$MODE" == fenced ]]; then
    for variable in \
        WRITER_TEST_FENCE \
        WRITER_TEST_FENCE_STATUS
    do
        value="${!variable:-}"

        [[ -n "$value" && -x "$value" ]] ||
            fail "$variable must reference an executable"
    done
fi

echo "RUN_CONFIGURATION_VALIDATED"
echo "MODE=$MODE"
echo "RUN_ID=$RUN_ID"

# A complete implementation must verify that the
# configured commands target only disposable resources.
# This gate remains closed until that verification
# is implemented and tested.

fail "LIVE_EXECUTION_DISABLED: isolated NFS and database adapters require verification"
