#!/usr/bin/env bash
# Read-only authenticated SQL check on the uniquely Ready replacement MariaDB.
set -Eeuo pipefail
NAMESPACE="${OPENMRS_CD_NAMESPACE:-openmrs37}"
DEPLOYMENT="${OPENMRS_CD_DEPLOYMENT:-openmrs-mariadb}"
SELECTOR="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"
AUTHORITY_FILE="${OPENMRS_CD_AUTHORITY_FILE:?Set OPENMRS_CD_AUTHORITY_FILE}"
[[ -r "$AUTHORITY_FILE" ]] || { echo 'Authority snapshot unavailable' >&2; exit 1; }
CANDIDATE="$(python3 - "$AUTHORITY_FILE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['candidate'])
PY
)"
POD="$(kubectl --request-timeout=10s get pods -n "$NAMESPACE" -l "$SELECTOR" -o json | python3 -c '
import json,sys
items=json.load(sys.stdin)["items"]
assert len(items)==1, "Expected exactly one MariaDB Pod"
p=items[0]
assert p["spec"].get("nodeName")==sys.argv[1], "Wrong recovery node"
assert not p["metadata"].get("deletionTimestamp"), "Pod terminating"
assert p["status"].get("phase")=="Running", "Pod not running"
assert any(c.get("type")=="Ready" and c.get("status")=="True" for c in p["status"].get("conditions",[])), "Pod not Ready"
print(p["metadata"]["name"])
' "$CANDIDATE")"
# Credentials are read inside the existing MariaDB container; never printed by this script.
# Verify server response and required OpenMRS core tables without modifying data.
timeout "${OPENMRS_CD_SQL_TIMEOUT_SECONDS:-30}" kubectl --request-timeout=20s exec -n "$NAMESPACE" "$POD" -c mariadb -- sh -eu -c '
  : "${MYSQL_DATABASE:?Missing MYSQL_DATABASE}"
  : "${MYSQL_USER:?Missing MYSQL_USER}"
  : "${MYSQL_PASSWORD:?Missing MYSQL_PASSWORD}"
  tables="$(MYSQL_PWD="$MYSQL_PASSWORD" mariadb --protocol=tcp -h 127.0.0.1 -P 3306 -u "$MYSQL_USER" --batch --skip-column-names "$MYSQL_DATABASE" -e "SHOW TABLES;")"
  for table in patient encounter obs; do
    printf "%s\n" "$tables" | grep -Fxq "$table" || { echo "Missing core table: $table" >&2; exit 1; }
  done
  echo "SQL_VERIFIED: authenticated query and core tables present"
'
