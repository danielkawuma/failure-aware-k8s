#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:?Usage: openmrs-mode-prepare.sh V0|T5|T10|T30|FA1}"

NS="${OPENMRS_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_BACKEND_DEPLOYMENT:-openmrs-backend}"
SELECTOR="${OPENMRS_BACKEND_SELECTOR:-app=openmrs-backend}"
TIMEOUT="${OPENMRS_MODE_TIMEOUT_SECONDS:-1200}"

case "$MODE" in
    V0)
        SECONDS_VALUE=300
        ;;
    T5)
        SECONDS_VALUE=5
        ;;
    T10)
        SECONDS_VALUE=10
        ;;
    T30)
        SECONDS_VALUE=30
        ;;
    FA1)
        SECONDS_VALUE=indefinite
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        exit 2
        ;;
esac

fail() {
    echo "[MODE] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[MODE] $*"
}

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] &&
    (( TIMEOUT > 0 )) ||
    fail "Invalid mode timeout"

command -v kubectl >/dev/null ||
    fail "kubectl missing"

command -v python3 >/dev/null ||
    fail "python3 missing"

# ------------------------------------------------------------
# Construct desired tolerations.
# Preserve unrelated tolerations.
# ------------------------------------------------------------

CURRENT="$(
    kubectl --request-timeout=15s \
        get deployment "$DEP" -n "$NS" -o json
)" || fail "Cannot retrieve Deployment"

PATCH="$(
    printf '%s' "$CURRENT" |
    python3 -c '
import json
import sys

obj = json.load(sys.stdin)
mode = sys.argv[1]
value = sys.argv[2]

spec = obj["spec"]["template"]["spec"]
existing = spec.get("tolerations", [])

keys = {
    "node.kubernetes.io/not-ready",
    "node.kubernetes.io/unreachable"
}

keep = [
    t for t in existing
    if not (
        t.get("key") in keys
        and t.get("effect") == "NoExecute"
    )
]

for key in sorted(keys):
    toleration = {
        "key": key,
        "operator": "Exists",
        "effect": "NoExecute"
    }

    if mode != "FA1":
        toleration["tolerationSeconds"] = int(value)

    keep.append(toleration)

print(json.dumps(keep, separators=(",", ":")))
' "$MODE" "$SECONDS_VALUE"
)" || fail "Cannot construct tolerations"

CURRENT_TOL="$(
    printf '%s' "$CURRENT" |
    python3 -c '
import json,sys
obj=json.load(sys.stdin)
print(json.dumps(
    obj["spec"]["template"]["spec"].get("tolerations", []),
    sort_keys=True
))
'
)"

DESIRED_TOL="$(
    printf '%s' "$PATCH" |
    python3 -c '
import json,sys
print(json.dumps(json.load(sys.stdin), sort_keys=True))
'
)"

# ------------------------------------------------------------
# Apply only when necessary.
# ------------------------------------------------------------

if [[ "$CURRENT_TOL" != "$DESIRED_TOL" ]]; then

    log "Applying $MODE tolerations ($SECONDS_VALUE)"

    JSON_PATCH="$(
        python3 - "$PATCH" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])

print(json.dumps([{
    "op": "add",
    "path": "/spec/template/spec/tolerations",
    "value": value
}]))
PY
    )"

    kubectl --request-timeout=15s \
        patch deployment "$DEP" \
        -n "$NS" \
        --type=json \
        -p "$JSON_PATCH" >/dev/null ||
        fail "Deployment patch failed"

    kubectl rollout status \
        deployment/"$DEP" \
        -n "$NS" \
        --timeout="${TIMEOUT}s" ||
        fail "Mode rollout did not complete"

else
    log "$MODE tolerations already configured; no rollout needed"
fi

# ------------------------------------------------------------
# Verify the Deployment template.
# ------------------------------------------------------------

verify_tolerations() {
    python3 -c '
import json
import sys

obj = json.load(sys.stdin)
kind = sys.argv[1]
mode = sys.argv[2]
expected = sys.argv[3]

if kind == "deployment":
    spec = obj["spec"]["template"]["spec"]
else:
    spec = obj["spec"]

keys = (
    "node.kubernetes.io/not-ready",
    "node.kubernetes.io/unreachable"
)

for key in keys:
    matches = [
        t for t in spec.get("tolerations", [])
        if t.get("key") == key
        and t.get("effect") == "NoExecute"
    ]

    assert len(matches) == 1, (
        f"Expected one toleration for {key}"
    )

    t = matches[0]

    assert t.get("operator") == "Exists", (
        f"Wrong operator for {key}"
    )

    if mode == "FA1":
        assert t.get("tolerationSeconds") is None, (
            f"FA1 toleration must be indefinite: {key}"
        )
    else:
        assert t.get("tolerationSeconds") == int(expected), (
            f"Wrong toleration duration: {key}"
        )
' "$1" "$MODE" "$SECONDS_VALUE"
}

DEPLOYMENT_JSON="$(
    kubectl --request-timeout=15s \
        get deployment "$DEP" -n "$NS" -o json
)" || fail "Cannot retrieve updated Deployment"

printf '%s' "$DEPLOYMENT_JSON" |
    verify_tolerations deployment ||
    fail "Deployment toleration verification failed"

log "Deployment template verified: $MODE"

# ------------------------------------------------------------
# Check current Pod state.
#
# Mode preparation does not require a Ready Pod.
# The backend reset and experiment runner enforce readiness
# before fault injection.
# ------------------------------------------------------------

PODS_JSON="$(
    kubectl --request-timeout=15s \
        get pods -n "$NS" \
        -l "$SELECTOR" -o json
)" || fail "Cannot retrieve backend Pods"

POD_STATE="$(
    printf '%s' "$PODS_JSON" |
    python3 -c '
import json
import sys

obj = json.load(sys.stdin)

pods = [
    p for p in obj["items"]
    if not p["metadata"].get("deletionTimestamp")
]

if len(pods) != 1:
    print("NOT_SINGLE")
    sys.exit(0)

pod = pods[0]

ready = (
    pod["status"].get("phase") == "Running"
    and any(
        c.get("type") == "Ready"
        and c.get("status") == "True"
        for c in pod["status"].get("conditions", [])
    )
)

print("READY" if ready else "NOT_READY")
'
)" || fail "Cannot inspect Pod readiness"

if [[ "$POD_STATE" == READY ]]; then

    POD_JSON="$(
        printf '%s' "$PODS_JSON" |
        python3 -c '
import json
import sys

obj = json.load(sys.stdin)

pods = [
    p for p in obj["items"]
    if not p["metadata"].get("deletionTimestamp")
]

assert len(pods) == 1

print(json.dumps(pods[0]))
'
    )"

    printf '%s' "$POD_JSON" |
        verify_tolerations pod ||
        fail "Running Pod tolerations do not match $MODE"

    log "VERIFIED $MODE: Ready Pod and tolerations correct"

else

    log "Pod state: $POD_STATE"
    log "Deployment tolerations prepared."
    log "Final readiness verification deferred to backend reset."

fi