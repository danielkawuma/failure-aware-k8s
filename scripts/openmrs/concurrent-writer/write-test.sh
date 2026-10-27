#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NS="failure-aware-writer-test"
POD="mariadb-restore"
RESULTS="$ROOT/experiments/evaluation/openmrs/concurrent-writer"
RUN="${1:-001}"

[[ "$RUN" =~ ^[0-9]{3}$ ]] || {
    echo "Usage: $0 RUN_ID" >&2
    exit 2
}

OUT="$RESULTS/write-baseline/run-$RUN"

[[ ! -e "$OUT" ]] || {
    echo "Run directory already exists" >&2
    exit 1
}

mkdir -p "$OUT"
chmod 700 "$OUT"

SQL='
CREATE TABLE IF NOT EXISTS openmrs.fa_writer_test (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    writer_id VARCHAR(32) NOT NULL,
    created_at TIMESTAMP(6) DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB;
'

kubectl exec -n "$NS" "$POD" -c mariadb -- \
  mariadb --protocol=socket \
  --socket=/tmp/mariadb.sock -uroot \
  -e "$SQL"

echo "=== ORIGINAL WRITER ==="

for i in $(seq 1 20); do
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"

    if kubectl exec -n "$NS" "$POD" -c mariadb -- \
      mariadb --protocol=socket \
      --socket=/tmp/mariadb.sock -uroot \
      -e "INSERT INTO openmrs.fa_writer_test(writer_id)
          VALUES ('original');" \
      >/dev/null 2>"$OUT/error-$i.txt"; then
        echo "$timestamp,original,$i,ACKNOWLEDGED" \
          >> "$OUT/commits.csv"
    else
        echo "$timestamp,original,$i,FAILED" \
          >> "$OUT/commits.csv"
    fi

    sleep 1
done

kubectl exec -n "$NS" "$POD" -c mariadb -- \
  mariadb --protocol=socket \
  --socket=/tmp/mariadb.sock -uroot -N -B \
  -e "SELECT COUNT(*) FROM openmrs.fa_writer_test;" \
  > "$OUT/final-count.txt"

echo "WRITE_BASELINE_COMPLETE"
echo "Evidence: $OUT"
