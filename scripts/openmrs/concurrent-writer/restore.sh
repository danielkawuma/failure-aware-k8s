#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

NS="failure-aware-writer-test"
POD="mariadb-restore"

SQL="$ROOT/backups/mariadb/openmrs-concurrent-writer-application.sql"

RESULTS="$ROOT/experiments/evaluation/openmrs/concurrent-writer/restore"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

test -s "$SQL" || fail "OpenMRS SQL file missing"

mkdir -p "$RESULTS"
chmod 700 "$RESULTS"
umask 077

if [[ -e "$RESULTS/RESTORE_COMPLETE" ]]; then
    fail "Restore already completed"
fi

kubectl get namespace "$NS" >/dev/null ||
    fail "Experimental namespace missing"

if ! kubectl get pod "$POD" -n "$NS" >/dev/null 2>&1; then
    echo "=== START MARIADB RESTORE POD ==="

    kubectl apply \
        -f "$ROOT/workloads/concurrent-writer/mariadb-restore.yaml"
fi

echo "=== WAIT FOR MARIADB CONNECTION ==="

READY=false

for attempt in $(seq 1 60); do

    if kubectl exec -n "$NS" "$POD" \
        -c mariadb -- \
        mariadb \
          --protocol=socket \
          --socket=/tmp/mariadb.sock \
          -uroot \
          -N -B \
          -e "SELECT 1;" \
          >/dev/null 2>&1; then

        READY=true
        break
    fi

    sleep 2
done

[[ "$READY" == true ]] ||
    fail "MariaDB did not become ready"

echo "MARIADB_CONNECTION_VERIFIED"

echo "=== CHECK FOR PREVIOUS IMPORT ==="

EXISTING="$(
    kubectl exec -n "$NS" "$POD" \
        -c mariadb -- \
        mariadb \
          --protocol=socket \
          --socket=/tmp/mariadb.sock \
          -uroot \
          -N -B \
          -e "
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema='openmrs';
          "
)"

[[ "$EXISTING" == "0" ]] ||
    fail "OpenMRS tables already exist; refusing repeated import"

echo "=== RESTORE OPENMRS DATABASE ==="

echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$RESULTS/restore-timing.txt"

set +e

kubectl exec -i -n "$NS" "$POD" \
    -c mariadb -- \
    mariadb \
      --protocol=socket \
      --socket=/tmp/mariadb.sock \
      -uroot \
      --abort-source-on-error \
    < "$SQL" \
    > "$RESULTS/import.stdout" \
    2> "$RESULTS/import.stderr"

RC=$?

set -e

echo "Import exit code: $RC" \
    >> "$RESULTS/restore-timing.txt"

if (( RC != 0 )); then
    echo "RESTORE_FAILED"
    echo "Review: $RESULTS/import.stderr"
    exit "$RC"
fi

echo "=== VERIFY RESTORED DATABASE ==="

TABLE_COUNT="$(
    kubectl exec -n "$NS" "$POD" \
        -c mariadb -- \
        mariadb \
          --protocol=socket \
          --socket=/tmp/mariadb.sock \
          -uroot \
          -N -B \
          -e "
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema='openmrs'
              AND table_type='BASE TABLE';
          "
)"

echo "TABLE_COUNT=$TABLE_COUNT" |
    tee "$RESULTS/table-count.txt"

[[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] ||
    fail "Invalid table count"

(( TABLE_COUNT >= 200 )) ||
    fail "Insufficient OpenMRS tables"

echo "=== DATABASE HEALTH ==="

kubectl exec -n "$NS" "$POD" \
    -c mariadb -- \
    mariadb \
      --protocol=socket \
      --socket=/tmp/mariadb.sock \
      -uroot \
      -N -B \
      -e "
        SELECT
          table_schema,
          COUNT(*)
        FROM information_schema.tables
        WHERE table_schema='openmrs'
        GROUP BY table_schema;
      " \
    > "$RESULTS/database-verification.txt"

kubectl logs -n "$NS" "$POD" \
    > "$RESULTS/mariadb.log" 2>&1 || true

date -u +%Y-%m-%dT%H:%M:%SZ \
    > "$RESULTS/RESTORE_COMPLETE"

echo
echo "OPENMRS_RESTORE_COMPLETE"
echo "Tables: $TABLE_COUNT"
echo "Evidence: $RESULTS"
