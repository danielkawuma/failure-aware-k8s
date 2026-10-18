#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCENARIO="${1:-}"
MODE="${2:-}"
RUN_ID="${3:-}"

NAMESPACE="openmrs37"
DEPLOYMENT="openmrs-backend"
SELECTOR="app=openmrs-backend"

HARNESS_BINARY="$REPO_ROOT/harness/target/debug/failure-aware-harness"
CONTROLLER_BINARY="$REPO_ROOT/controller/target/debug/failure-aware-controller"

FAULT_SCRIPT="$SCRIPT_DIR/fault.sh"
OPENMRS_C_FAULT="$SCRIPT_DIR/openmrs-c-fault.sh"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

BASELINE_SECONDS="${BASELINE_SECONDS:-30}"
FAULT_SECONDS="${FAULT_SECONDS:-360}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-480}"
POST_FAULT_SECONDS="${POST_FAULT_SECONDS:-30}"

RUN_ROOT="$REPO_ROOT/experiments/evaluation/openmrs"

case "$SCENARIO" in
    scenario-b|scenario-c) ;;
    *)
        echo "Usage: $0 scenario-b|scenario-c V0|T5|T10|T30|FA1 RUN_ID"
        exit 2
        ;;
esac

case "$MODE" in
    V0|T5|T10|T30|FA1) ;;
    *)
        echo "Invalid benchmark mode: $MODE"
        exit 2
        ;;
esac

[[ "$RUN_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo "Invalid run identifier"
    exit 2
}

RUN_DIR="$RUN_ROOT/$SCENARIO/$MODE/run-$RUN_ID"

[[ ! -e "$RUN_DIR" ]] || {
    echo "Run directory already exists: $RUN_DIR"
    exit 1
}

mkdir -p "$RUN_DIR"

HARNESS_PID=""
CONTROLLER_PID=""
FAULT_ATTEMPTED=false
FAULT_CLEARED=false
CONFIG_CHANGED=false
SUCCESS=false

utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
}

log() {
    printf '[%s] %s\n' "$(utc_now)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

record() {
    utc_now > "$RUN_DIR/$1"
}

kube() {
    kubectl --request-timeout=15s "$@"
}

get_pods_json() {
    kube get pods \
        -n "$NAMESPACE" \
        -l "$SELECTOR" \
        -o json
}

pod_snapshot() {
    get_pods_json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    print(
        p["metadata"]["name"],
        p["spec"].get("nodeName",""),
        p["status"].get("phase",""),
        bool(p["metadata"].get("deletionTimestamp")),
        sep="|"
    )
'
}

original_pod_details() {
    get_pods_json | python3 -c '
import json,sys
pods=[
    p for p in json.load(sys.stdin)["items"]
    if p["status"].get("phase")=="Running"
    and not p["metadata"].get("deletionTimestamp")
]
if len(pods)!=1:
    sys.exit(1)
p=pods[0]
print(p["metadata"]["name"])
print(p["spec"].get("nodeName",""))
print(p["status"].get("podIP",""))
'
}

node_ip() {
    kube get node "$1" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

save_cluster_state() {
    local prefix="$1"

    kube get nodes -o wide \
        > "$RUN_DIR/${prefix}-nodes.txt" || true

    kube get pods -n "$NAMESPACE" -o wide \
        > "$RUN_DIR/${prefix}-pods.txt" || true

    kube get endpointslices \
        -n "$NAMESPACE" -o yaml \
        > "$RUN_DIR/${prefix}-endpointslices.yaml" || true

    kube get deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" -o yaml \
        > "$RUN_DIR/${prefix}-deployment.yaml" || true

    kube get events -n "$NAMESPACE" \
        --sort-by=.metadata.creationTimestamp \
        > "$RUN_DIR/${prefix}-events.txt" || true
}

restore_template() {
    if [[ "$CONFIG_CHANGED" != true ]]; then
        return 0
    fi

    log "Restoring original backend Pod template"

    python3 - "$RUN_DIR/original-template.json" > "$RUN_DIR/restore-patch.json" <<'PYRESTORE'
import json,sys
with open(sys.argv[1]) as f: template=json.load(f)
print(json.dumps([{"op":"replace","path":"/spec/template","value":template}]))
PYRESTORE
    kube patch deployment "$DEPLOYMENT" -n "$NAMESPACE" \
        --type=json --patch-file "$RUN_DIR/restore-patch.json"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM

    set +e

    if [[ "$FAULT_ATTEMPTED" == true &&
          "$FAULT_CLEARED" != true ]]; then
        log "Attempting fault cleanup"

        if [[ "$SCENARIO" == scenario-c ]]; then
            "$OPENMRS_C_FAULT" clear > "$RUN_DIR/fault-cleanup.log" 2>&1
        else
            "$FAULT_SCRIPT" "$SCENARIO" clear > "$RUN_DIR/fault-cleanup.log" 2>&1
        fi

        if [[ $? -eq 0 ]]; then
            FAULT_CLEARED=true
        else
            log "WARNING: fault cleanup failed"
        fi
    fi

    if [[ -n "$HARNESS_PID" ]]; then
        kill -INT "$HARNESS_PID" 2>/dev/null
        wait "$HARNESS_PID" 2>/dev/null
    fi

    if [[ -n "$CONTROLLER_PID" ]]; then
        kill "$CONTROLLER_PID" 2>/dev/null
        wait "$CONTROLLER_PID" 2>/dev/null
    fi

    if [[ "$FAULT_ATTEMPTED" != true ||
          "$FAULT_CLEARED" == true ]]; then
        restore_template \
            > "$RUN_DIR/template-restore.log" 2>&1
        RESTORE_RC=$?
    else
        RESTORE_RC=1
        log "Template restoration deferred: fault not confirmed cleared"
    fi

    save_cluster_state "final"

    if [[ "$SUCCESS" == true &&
          "$RESTORE_RC" -eq 0 ]]; then
        if [[ "${OPENMRS_ENABLE_FAULTS:-false}" == true && "$FAULT_ATTEMPTED" == true ]]; then
            touch "$RUN_DIR/COMPLETE"
            log "RUN COMPLETE: $RUN_DIR"
        else
            touch "$RUN_DIR/PREFLIGHT_COMPLETE"
            log "PREFLIGHT COMPLETE: $RUN_DIR"
        fi
    else
        touch "$RUN_DIR/INCOMPLETE"
        log "RUN INCOMPLETE: $RUN_DIR"
    fi

    exit "$rc"
}

trap cleanup EXIT INT TERM

log "OpenMRS experiment: $SCENARIO / $MODE / $RUN_ID"

command -v kubectl >/dev/null || fail "kubectl unavailable"
command -v python3 >/dev/null || fail "python3 unavailable"
command -v curl >/dev/null || fail "curl unavailable"

[[ -x "$HARNESS_BINARY" ]] ||
    fail "Harness binary missing"

[[ -f "$SSH_KEY" ]] ||
    fail "SSH key missing"

if [[ "$MODE" == FA1 ]]; then
    [[ -x "$CONTROLLER_BINARY" ]] ||
        fail "Controller binary missing"
fi

# --------------------------------------------------
# Save exact original configuration.
# --------------------------------------------------

kube get deployment "$DEPLOYMENT" \
    -n "$NAMESPACE" -o json \
    > "$RUN_DIR/original-deployment.json"

python3 - "$RUN_DIR/original-deployment.json" \
    "$RUN_DIR/original-template.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    d=json.load(f)
with open(sys.argv[2],"w") as f:
    json.dump(d["spec"]["template"],f)
PY

save_cluster_state "before"

DETAILS="$(original_pod_details)" ||
    fail "Expected exactly one running OpenMRS backend"

ORIGINAL_POD="$(sed -n '1p' <<< "$DETAILS")"
ORIGINAL_NODE="$(sed -n '2p' <<< "$DETAILS")"
ORIGINAL_IP="$(sed -n '3p' <<< "$DETAILS")"

[[ -n "$ORIGINAL_NODE" && -n "$ORIGINAL_IP" ]] ||
    fail "Original placement unavailable"

log "Original Pod: $ORIGINAL_POD"
log "Original Node: $ORIGINAL_NODE"

# --------------------------------------------------
# Safety checks.
# --------------------------------------------------

if [[ "$SCENARIO" == scenario-c ]]; then
    [[ -x "$OPENMRS_C_FAULT" ]] || fail "OpenMRS Scenario C fault helper unavailable"
    # The controller refuses conflicting hostname selectors. Placement must
    # be prepared between runs, never modified during a measured fault.
    SELECTOR_HOST="$(kube get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}')"
    [[ -z "$SELECTOR_HOST" ]] || fail "Hostname selector still pinned; run placement preparation first"
fi

[[ "$ORIGINAL_NODE" == "k3s-worker1" ]] ||
    fail "Current fault backend is configured for Worker1"

# --------------------------------------------------
# Select native toleration configuration.
# --------------------------------------------------

case "$MODE" in
    V0)
        TOLERATION_SECONDS=""
        ;;
    T5)
        TOLERATION_SECONDS=5
        ;;
    T10)
        TOLERATION_SECONDS=10
        ;;
    T30)
        TOLERATION_SECONDS=30
        ;;
    FA1)
        TOLERATION_SECONDS=""
        ;;
esac

if [[ "$MODE" != FA1 ]]; then
    # Only alter the two relevant NoExecute tolerations.
    # Preserve all other existing Pod tolerations.
    python3 - \
      "$RUN_DIR/original-template.json" \
      "$RUN_DIR/benchmark-template.json" \
      "$TOLERATION_SECONDS" <<'PY'
import json,sys

with open(sys.argv[1]) as f:
    template=json.load(f)

seconds=sys.argv[3]
spec=template["spec"]

existing=spec.get("tolerations",[])

existing=[
    t for t in existing
    if not (
        t.get("key") in (
            "node.kubernetes.io/not-ready",
            "node.kubernetes.io/unreachable"
        )
        and t.get("effect")=="NoExecute"
    )
]

if seconds:
    for key in (
        "node.kubernetes.io/not-ready",
        "node.kubernetes.io/unreachable"
    ):
        existing.append({
            "key":key,
            "operator":"Exists",
            "effect":"NoExecute",
            "tolerationSeconds":int(seconds)
        })

if existing:
    spec["tolerations"]=existing
else:
    spec.pop("tolerations",None)

with open(sys.argv[2],"w") as f:
    json.dump(template,f)
PY

    PATCH="$(
        python3 - "$RUN_DIR/benchmark-template.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    template=json.load(f)
print(json.dumps({"spec":{"template":template}}))
PY
    )"

    CONFIG_CHANGED=true

    kube patch deployment "$DEPLOYMENT" \
        -n "$NAMESPACE" \
        --type=merge \
        -p "$PATCH"

    kube rollout status deployment/"$DEPLOYMENT" \
        -n "$NAMESPACE" --timeout=1200s
fi

# --------------------------------------------------
# Verify new starting state.
# --------------------------------------------------

DETAILS="$(original_pod_details)" ||
    fail "No clean backend Pod after configuration"

ORIGINAL_POD="$(sed -n '1p' <<< "$DETAILS")"
ORIGINAL_NODE="$(sed -n '2p' <<< "$DETAILS")"
ORIGINAL_IP="$(sed -n '3p' <<< "$DETAILS")"

[[ "$ORIGINAL_NODE" == "k3s-worker1" ]] ||
    fail "Backend not on original target node"

kube get pod "$ORIGINAL_POD" \
    -n "$NAMESPACE" -o json \
    > "$RUN_DIR/initial-pod.json"

# --------------------------------------------------
# Require explicit fault authorization.
# --------------------------------------------------

if [[ "${OPENMRS_ENABLE_FAULTS:-false}" != true ]]; then
    log "Dry-run preflight complete"
    log "Set OPENMRS_ENABLE_FAULTS=true for fault execution"
    SUCCESS=true
    exit 0
fi

# --------------------------------------------------
# Start observation.
# --------------------------------------------------

case "$SCENARIO" in
    scenario-b)
        HARNESS_CONFIG="$REPO_ROOT/harness/config/openmrs-scenario-b.json"
        ;;
    scenario-c)
        HARNESS_CONFIG="$REPO_ROOT/harness/config/openmrs-scenario-c.json"
        ;;
esac

export HARNESS_CONFIG

"$HARNESS_BINARY" \
    > "$RUN_DIR/harness.log" 2>&1 &

HARNESS_PID=$!

if [[ "$MODE" == FA1 ]]; then
    (
        cd "$REPO_ROOT"
        FAILURE_AWARE_CONTROLLER_CONFIG="$REPO_ROOT/controller/config/openmrs-backend.json" \
          "$CONTROLLER_BINARY"
    ) > "$RUN_DIR/controller.log" 2>&1 &

    CONTROLLER_PID=$!
fi

log "Baseline observation: ${BASELINE_SECONDS}s"
sleep "$BASELINE_SECONDS"

kill -0 "$HARNESS_PID" 2>/dev/null ||
    fail "Harness exited before fault injection"

if [[ "$MODE" == FA1 ]]; then
    kill -0 "$CONTROLLER_PID" 2>/dev/null ||
        fail "Controller exited before fault injection"
fi

if [[ "$SCENARIO" == scenario-c ]]; then
    # Establish that the independent path works BEFORE injecting the fault.
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      ubuntu@102.34.160.103 \
      "curl -fsS --connect-timeout 2 --max-time 10 http://$ORIGINAL_IP:8080/openmrs/health/started" \
      > "$RUN_DIR/old-backend-before-fault.txt" 2>&1 || \
      fail "Worker2 cannot reach original backend before fault; invalid test"
fi

record "fault-start-time.txt"

log "Injecting $SCENARIO fault"

FAULT_ATTEMPTED=true

if [[ "$SCENARIO" == scenario-c ]]; then
    "$OPENMRS_C_FAULT" apply "$ORIGINAL_IP" \
      > "$RUN_DIR/fault-apply.log" 2>&1 || fail "Fault injection failed"
    "$OPENMRS_C_FAULT" status >> "$RUN_DIR/fault-apply.log" 2>&1 || fail "Fault not verified"
    # Independent client check: the old backend must become unreachable.
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      ubuntu@102.34.160.103 \
      "curl -fsS --connect-timeout 2 --max-time 4 http://$ORIGINAL_IP:8080/openmrs/health/started" \
      > "$RUN_DIR/old-backend-during-fault.txt" 2>&1; then
        fail "Original backend still reachable from Worker2: invalid Scenario C fault"
    fi
else
    "$FAULT_SCRIPT" "$SCENARIO" apply \
      > "$RUN_DIR/fault-apply.log" 2>&1 || fail "Fault injection failed"
fi

log "Observing partition for ${FAULT_SECONDS}s"

sleep "$FAULT_SECONDS"

record "fault-clear-time.txt"

if [[ "$SCENARIO" == scenario-c ]]; then
    "$OPENMRS_C_FAULT" clear > "$RUN_DIR/fault-clear.log" 2>&1 || fail "Fault cleanup failed"
else
    "$FAULT_SCRIPT" "$SCENARIO" clear > "$RUN_DIR/fault-clear.log" 2>&1 || fail "Fault cleanup failed"
fi

FAULT_CLEARED=true

log "Post-fault observation: ${POST_FAULT_SECONDS}s"

sleep "$POST_FAULT_SECONDS"

save_cluster_state "after"

if [[ "$SCENARIO" == scenario-c ]]; then
    get_pods_json > "$RUN_DIR/recovery-pods.json"
    python3 - "$ORIGINAL_POD" "$ORIGINAL_NODE" "$RUN_DIR/recovery-pods.json" <<'PYRECOVERY' || fail "No Ready replacement on another node"
import json,sys
old,node,path=sys.argv[1:]
with open(path) as f: pods=json.load(f)['items']
valid=[p for p in pods if p['metadata']['name']!=old
  and p.get('spec',{}).get('nodeName') not in ('',node,None)
  and p.get('status',{}).get('phase')=='Running'
  and not p['metadata'].get('deletionTimestamp')
  and any(c.get('type')=='Ready' and c.get('status')=='True' for c in p.get('status',{}).get('conditions',[]))]
if len(valid)!=1: sys.exit(1)
print('Recovery:',valid[0]['metadata']['name'],valid[0]['spec']['nodeName'])
PYRECOVERY
fi

cat > "$RUN_DIR/experiment-metadata.json" <<EOF
{
  "scenario": "$SCENARIO",
  "benchmark_mode": "$MODE",
  "run_id": "$RUN_ID",
  "namespace": "$NAMESPACE",
  "deployment": "$DEPLOYMENT",
  "original_pod": "$ORIGINAL_POD",
  "original_node": "$ORIGINAL_NODE",
  "original_pod_ip": "$ORIGINAL_IP",
  "fault_duration_seconds": $FAULT_SECONDS,
  "git_commit": "$(git -C "$REPO_ROOT" rev-parse HEAD)"
}
EOF

SUCCESS=true
log "Experiment observation completed"