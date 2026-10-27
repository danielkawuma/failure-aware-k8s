#!/usr/bin/env bash
set -Eeuo pipefail

NS="failure-aware-writer-test"
SERVER="102.34.160.36"
EXPORT="/srv/failure-aware/concurrent-writer/database/w2-001"
IMAGE="mariadb:10.11.19"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$ROOT/experiments/evaluation/openmrs/concurrent-writer/fenced/run-001"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$ROOT/experiments/evaluation/openmrs/concurrent-writer" ]] ||
    fail "Experimental evidence directory missing"

if kubectl get pod w2-original -n "$NS" >/dev/null 2>&1; then
    fail "W2 original Pod already exists"
fi

if kubectl get pod w2-replacement -n "$NS" >/dev/null 2>&1; then
    fail "W2 replacement Pod already exists"
fi

if [[ -e "$OUT" ]]; then
    fail "W2 run directory already exists"
fi

mkdir -p "$OUT"
chmod 700 "$OUT"

echo "=== VERIFY EXPERIMENTAL NFS ==="

ssh ubuntu@k3s-worker3 \
    'sudo test -d /srv/failure-aware/concurrent-writer/database/w2-001'

echo "=== VERIFY FENCE IS ABSENT ==="

ssh ubuntu@k3s-worker3 \
    'sudo /usr/local/sbin/fa-writer-fence-w2 status' \
    > "$OUT/fence-before.txt" 2>&1 && {
        fail "Fence already active"
    }

echo "=== START ORIGINAL MARIADB ==="

cat <<YAML | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata:
  name: w2-original
  labels:
    experiment: concurrent-writer
    arm: fenced
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 30
  nodeSelector:
    kubernetes.io/hostname: k3s-worker1
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

echo "=== WAIT FOR ORIGINAL SQL READINESS ==="

READY=false

for attempt in $(seq 1 60); do
    if kubectl exec -n "$NS" w2-original -c mariadb -- \
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
    kubectl logs -n "$NS" w2-original \
        > "$OUT/original.log" 2>&1 || true

    fail "Original MariaDB did not become ready"
fi

echo "=== ORIGINAL SQL WRITE ==="

kubectl exec -n "$NS" w2-original -c mariadb -- \
    mariadb \
      --protocol=socket \
      --socket=/tmp/mariadb.sock \
      -uroot \
      -e "
        INSERT INTO openmrs.fa_writer_test(writer_id)
        VALUES ('w2-original');
      "

date -u +%Y-%m-%dT%H:%M:%SZ \
    > "$OUT/original-write-time.txt"

kubectl logs -n "$NS" w2-original \
    > "$OUT/original-before-fence.log" 2>&1 || true

echo
echo "W2_ORIGINAL_WRITER_READY"
echo "Evidence: $OUT"
echo "No fencing applied."
