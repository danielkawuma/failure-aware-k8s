#!/usr/bin/env bash
set -Eeuo pipefail

NS="failure-aware-writer-test"
SERVER="102.34.160.36"
EXPORT="/srv/failure-aware/concurrent-writer/database/w1-001"
IMAGE="mariadb:10.11.19"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$ROOT/experiments/evaluation/openmrs/concurrent-writer/unfenced/run-001"

mkdir -p "$OUT"
chmod 700 "$OUT"

for POD in w1-original w1-replacement; do
    if kubectl get pod "$POD" -n "$NS" >/dev/null 2>&1; then
        echo "ERROR: Pod already exists: $POD"
        exit 1
    fi
done

create_pod() {
    local name="$1"
    local node="$2"

    cat <<YAML | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    experiment: concurrent-writer
    arm: unfenced
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 30
  nodeSelector:
    kubernetes.io/hostname: ${node}
  securityContext:
    runAsUser: 999
    runAsGroup: 999
  containers:
    - name: mariadb
      image: ${IMAGE}
      command:
        - sh
        - -ec
        - |
          exec mariadbd \
            --datadir=/var/lib/mysql \
            --socket=/tmp/mariadb.sock \
            --pid-file=/tmp/mariadb.pid \
            --skip-networking \
            --innodb-flush-log-at-trx-commit=1
      volumeMounts:
        - name: database
          mountPath: /var/lib/mysql
  volumes:
    - name: database
      nfs:
        server: ${SERVER}
        path: ${EXPORT}
YAML
}

echo "=== START ORIGINAL MARIADB ==="
create_pod w1-original k3s-worker1

echo "=== WAIT FOR ORIGINAL SQL READINESS ==="

READY=false

for attempt in $(seq 1 60); do
    if kubectl exec -n "$NS" w1-original -c mariadb -- \
        mariadb \
          --protocol=socket \
          --socket=/tmp/mariadb.sock \
          -uroot -N -B \
          -e "SELECT 1;" \
          >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 2
done

if [[ "$READY" != true ]]; then
    kubectl logs -n "$NS" w1-original > "$OUT/original.log" 2>&1 || true
    echo "ERROR: Original MariaDB did not become ready"
    exit 1
fi

echo "ORIGINAL_DATABASE_READY"

echo "=== VERIFY ORIGINAL WRITE ==="

kubectl exec -n "$NS" w1-original -c mariadb -- \
    mariadb \
      --protocol=socket \
      --socket=/tmp/mariadb.sock \
      -uroot \
      -e "
        INSERT INTO openmrs.fa_writer_test(writer_id)
        VALUES ('w1-original');
      "

date -u +%Y-%m-%dT%H:%M:%SZ \
    > "$OUT/replacement-attempt-time.txt"

echo "=== ATTEMPT UNFENCED REPLACEMENT ==="

create_pod w1-replacement k3s-worker2

sleep 30

kubectl get pods -n "$NS" -o wide \
    > "$OUT/pod-status.txt"

kubectl logs -n "$NS" w1-original \
    > "$OUT/original.log" 2>&1 || true

kubectl logs -n "$NS" w1-replacement \
    > "$OUT/replacement.log" 2>&1 || true

echo "=== REPLACEMENT SQL READINESS ==="

if kubectl exec -n "$NS" w1-replacement -c mariadb -- \
    mariadb \
      --protocol=socket \
      --socket=/tmp/mariadb.sock \
      -uroot -N -B \
      -e "SELECT 1;" \
      >/dev/null 2>&1; then
    echo "REPLACEMENT_SQL_READY" |
        tee "$OUT/replacement-result.txt"
else
    echo "REPLACEMENT_SQL_NOT_READY" |
        tee "$OUT/replacement-result.txt"
fi

echo "W1_OBSERVATION_COMPLETE"
echo "Evidence: $OUT"
