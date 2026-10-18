#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only authenticated MariaDB checks against replacement Pod.
# Requires database credentials available inside the container.

RUN_DIR="${1:?Usage: $0 /path/to/run-directory}"
AUTHORITY_FILE="$RUN_DIR/controller-authority.json"

[[ -r "$AUTHORITY_FILE" ]] || {
    echo 'Missing controller-authority.json' >&2
    exit 2
}

NS="${OPENMRS_CD_NAMESPACE:-openmrs37}"
SELECTOR="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"
DB="${OPENMRS_CD_DATABASE:-openmrs}"

[[ "$DB" =~ ^[A-Za-z0-9_]+$ ]] || {
    echo 'Invalid database name' >&2
    exit 2
}

CANDIDATE="$(
python3 - "$AUTHORITY_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['candidate'])
PY
)"

OUT_DIR="${OPENMRS_CD_VALIDATION_DIR:-$RUN_DIR/post-recovery-validation}"
mkdir -p "$OUT_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT_DIR/data-access-$STAMP.log"

exec > >(tee "$LOG") 2>&1

echo "TEST_TIME_UTC=$STAMP"
echo "RUN_DIR=$RUN_DIR"
echo "CANDIDATE=$CANDIDATE"
echo "DATABASE=$DB"

echo '=== FIND UNIQUE READY REPLACEMENT ==='

POD="$(
kubectl --request-timeout=10s \
    get pods -n "$NS" -l "$SELECTOR" -o json |
python3 -c '
import json, sys

candidate = sys.argv[1]
pods = json.load(sys.stdin)["items"]

assert len(pods) == 1, "Expected exactly one database Pod"

pod = pods[0]

assert pod["spec"].get("nodeName") == candidate
assert not pod["metadata"].get("deletionTimestamp")
assert pod["status"].get("phase") == "Running"

assert any(
    c.get("type") == "Ready"
    and c.get("status") == "True"
    for c in pod["status"].get("conditions", [])
)

print(pod["metadata"]["name"])
' "$CANDIDATE"
)"

echo "REPLACEMENT_POD=$POD"
echo '=== AUTHENTICATED READ-ONLY SQL ==='

SQL_OUTPUT="$(
kubectl --request-timeout=45s exec \
    -n "$NS" "$POD" -- sh -c '
    set -eu

    PASS="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"

    [ -n "$PASS" ] || {
        echo "DB_CREDENTIAL_UNAVAILABLE" >&2
        exit 4
    }

    export MYSQL_PWD="$PASS"

    exec mariadb \
        --connect-timeout=10 \
        --batch \
        --skip-column-names \
        -uroot \
        -e "$1"
' sh "
SELECT 'SQL_OK', VERSION();
SELECT COUNT(*)
FROM information_schema.tables
WHERE table_schema='$DB';
SELECT COUNT(*)
FROM information_schema.columns
WHERE table_schema='$DB';
"
)" || {
    echo 'RESULT=FAIL_AUTHENTICATED_SQL'
    exit 1
}

printf '%s\n' "$SQL_OUTPUT"

if ! grep -q '^SQL_OK[[:space:]]' <<< "$SQL_OUTPUT"; then
    echo 'RESULT=FAIL_SQL_RESPONSE'
    exit 1
fi

TABLE_COUNT="$(printf '%s\n' "$SQL_OUTPUT" | sed -n '2p')"
COLUMN_COUNT="$(printf '%s\n' "$SQL_OUTPUT" | sed -n '3p')"

if ! [[ "$TABLE_COUNT" =~ ^[0-9]+$ &&
        "$COLUMN_COUNT" =~ ^[0-9]+$ ]] ||
   (( TABLE_COUNT < 1 || COLUMN_COUNT < 1 )); then
    echo 'RESULT=FAIL_SCHEMA_NOT_FOUND_OR_EMPTY'
    exit 1
fi

echo "SCHEMA_TABLE_COUNT=$TABLE_COUNT"
echo "SCHEMA_COLUMN_COUNT=$COLUMN_COUNT"

echo 'RESULT=PASS_DATABASE_REACHABLE_SCHEMA_PRESENT'
echo 'NOTE=This does not prove all pre-fault committed records survived.'
echo 'NOTE=Compare pre-fault and recovered records for integrity verification.'