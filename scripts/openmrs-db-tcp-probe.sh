#!/usr/bin/env bash
set -Eeuo pipefail
# Diagnostic only: TCP connectivity is NOT proof of database write authority.
NS="${OPENMRS_DB_NAMESPACE:-openmrs37}"
POD="$(kubectl get pod -n "$NS" -l app=openmrs-mariadb -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || exit 1
kubectl exec -n "$NS" "$POD" -- sh -c 'mariadb-admin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD"'
echo 'DATABASE_PROCESS_RESPONSIVE: not an independent partition probe.'
