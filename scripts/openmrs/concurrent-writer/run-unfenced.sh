#!/usr/bin/env bash
set -Eeuo pipefail

NS="failure-aware-writer-test"
SERVER="102.34.160.36"
EXPORT="/srv/failure-aware/concurrent-writer/database/restore-001"
IMAGE="mariadb:10.11.19"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RESULTS="$ROOT/experiments/evaluation/openmrs/concurrent-writer/unfenced/run-001"

mkdir -p "$RESULTS"

echo "=== UNFENCED CONCURRENT-WRITER TEST ==="

kubectl get namespace "$NS" >/dev/null
kubectl get node k3s-worker1 >/dev/null
kubectl get node k3s-worker2 >/dev/null

if kubectl get pod writer-original -n "$NS" >/dev/null 2>&1 ||
   kubectl get pod writer-replacement -n "$NS" >/dev/null 2>&1; then
    echo "ERROR: Experimental writer Pods already exist"
    exit 1
fi

cat <<YAML | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata:
  name: writer-original
  labels:
    experiment: concurrent-writer
    writer: original
spec:
  restartPolicy: Never
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
            --socket=/tmp/mysql.sock \
            --pid-file=/tmp/mysql.pid \
            --skip-networking
      volumeMounts:
        - name: database
          mountPath: /var/lib/mysql
  volumes:
    - name: database
      nfs:
        server: ${SERVER}
        path: ${EXPORT}
---
apiVersion: v1
kind: Pod
metadata:
  name: writer-replacement
  labels:
    experiment: concurrent-writer
    writer: replacement
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: k3s-worker2
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
            --socket=/tmp/mysql.sock \
            --pid-file=/tmp/mysql.pid \
            --skip-networking
      volumeMounts:
        - name: database
          mountPath: /var/lib/mysql
  volumes:
    - name: database
      nfs:
        server: ${SERVER}
        path: ${EXPORT}
YAML

echo "=== OBSERVE STARTUP ==="

sleep 30

kubectl get pods -n "$NS" -o wide \
    | tee "$RESULTS/pod-status.txt"

kubectl logs -n "$NS" writer-original \
    > "$RESULTS/original.log" 2>&1 || true

kubectl logs -n "$NS" writer-replacement \
    > "$RESULTS/replacement.log" 2>&1 || true

echo "=== DATABASE STARTUP OBSERVATIONS ==="

grep -iE \
    'ready for connections|lock|error|fail|innodb' \
    "$RESULTS/original.log" \
    "$RESULTS/replacement.log" \
    | tail -n 60 || true

echo "UNFENCED_OBSERVATION_COMPLETE"
echo "Results: $RESULTS"
