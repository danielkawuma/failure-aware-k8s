#!/usr/bin/env bash
# Scenario A - genuine worker shutdown experiment.
#
# Native: Kubernetes schedules replacement on any eligible worker.
# FA1: Controller-selected recovery candidate is k3s-worker2.
#
# Standalone baseline: Nginx on Worker1 port 8081.
# Shutdown: SSH systemctl poweroff.
# Restart: Manual OpenStack Horizon.
#
# COMPLETE means experiment execution, evidence collection,
# and final cleanup verification succeeded.
# It does not mean workload recovery succeeded.
#
# Existing Scenario B/C scripts are not modified.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/experiment-config.sh"

MODE="${1:?Usage: scenario-a-run.sh native|failure-aware RUN}"
NUMBER="${2:?Run number required}"

[[ "$MODE" == native || "$MODE" == failure-aware ]] || {
    echo "Invalid mode: $MODE"
    exit 2
}

[[ "$NUMBER" =~ ^[0-9]+$ ]] || {
    echo "Invalid run number: $NUMBER"
    exit 2
}

RUN="$(printf '%03d' "$((10#$NUMBER))")"
DIR="$ROOT/experiments/evaluation/scenario-a/$MODE/run-$RUN"

if [[ -e "$DIR" ]]; then
    echo "Run directory already exists: $DIR"
    exit 1
fi

mkdir -p "$DIR"
touch "$DIR/INCOMPLETE"

exec > >(tee -a "$DIR/run.log") 2>&1

HOLD="${SCENARIO_A_HOLD_SECONDS:-480}"
BOOT_TIMEOUT="${SCENARIO_A_BOOT_TIMEOUT_SECONDS:-1800}"
BASELINE="${SCENARIO_A_BASELINE_SECONDS:-15}"
POST_RETURN="${SCENARIO_A_POST_RETURN_SECONDS:-60}"
POD_WAIT="${SCENARIO_A_POD_WAIT_SECONDS:-180}"

FINAL_HTTP_WAIT="${SCENARIO_A_FINAL_HTTP_WAIT_SECONDS:-60}"
FINAL_HTTP_STABLE="${SCENARIO_A_FINAL_HTTP_STABLE_COUNT:-3}"

HARNESS_PID=""
PROBE_PID=""
CONTROLLER_PID=""

VM_OFF=false
SUCCESS=false
ORIGINAL_POD=""
ORIGINAL_UID=""
HARNESS_DIR=""

utc() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

record() {
    utc > "$DIR/$1"
}

log() {
    printf '[SCENARIO-A] %s %s\n' "$(utc)" "$*"
}

fail() {
    log "BLOCKED: $*"
    printf '%s\n' "$*" > "$DIR/failure-reason.txt"
    exit 1
}

ping_ok() {
    ping -n -c 1 -W 1 "$WORKER1_IP" >/dev/null 2>&1
}

ssh_ok() {
    timeout 8 ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$WORKER1_SSH" true >/dev/null 2>&1
}

node_ready() {
    local node="$1"

    [[ "$(
        kubectl --request-timeout=5s get node "$node" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
          2>/dev/null
    )" == True ]]
}

http_ok() {
    curl -fsS \
        --connect-timeout 2 \
        --max-time 4 \
        "$1" >/dev/null 2>&1
}

# Require repeated successful HTTP responses after reset.
# This prevents a transient Service/EndpointSlice convergence
# delay from incorrectly failing an otherwise completed run.

wait_stable_http() {
    local url="$1"
    local prefix="$2"
    local timeout_seconds="${3:-60}"
    local required_successes="${4:-3}"

    local deadline=$((SECONDS + timeout_seconds))
    local consecutive=0
    local first_success=false

    log "Waiting for stable HTTP: $prefix"

    while (( SECONDS < deadline )); do

        if http_ok "$url"; then

            if [[ "$first_success" == false ]]; then
                record "${prefix}-first-success.txt"
                first_success=true
            fi

            consecutive=$((consecutive + 1))

            log "$prefix HTTP success $consecutive/$required_successes"

            if (( consecutive >= required_successes )); then
                record "${prefix}-stable.txt"
                log "${prefix}_HTTP_STABLE"
                return 0
            fi

        else
            consecutive=0
            log "$prefix HTTP unavailable; retrying"
        fi

        sleep 2
    done

    log "$prefix HTTP did not stabilize within ${timeout_seconds}s"
    return 1
}

# Wait for exactly one non-terminating, Running and Ready
# Nginx Pod on Worker1.
#
# Three consecutive successful observations are required.
# Initial and final snapshots are written to separate files.

wait_clean_nginx() {
    local output="$1"
    local timeout_seconds="${2:-180}"
    local deadline=$((SECONDS + timeout_seconds))
    local stable=0

    while (( SECONDS < deadline )); do

        if kubectl --request-timeout=10s \
            -n "$NAMESPACE" \
            get pods -l "$LABEL_SELECTOR" \
            -o json > "$output"; then

            if python3 - "$output" "$WORKER1_NODE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    pods = json.load(handle)["items"]

if len(pods) != 1:
    raise SystemExit(1)

pod = pods[0]

if pod["spec"].get("nodeName") != sys.argv[2]:
    raise SystemExit(1)

if pod.get("status", {}).get("phase") != "Running":
    raise SystemExit(1)

if pod["metadata"].get("deletionTimestamp"):
    raise SystemExit(1)

if not any(
    c.get("type") == "Ready"
    and c.get("status") == "True"
    for c in pod.get("status", {}).get("conditions", [])
):
    raise SystemExit(1)
PY
            then
                stable=$((stable + 1))

                if (( stable >= 3 )); then
                    log "CLEAN_NGINX_VERIFIED"
                    return 0
                fi
            else
                stable=0
            fi

        else
            stable=0
        fi

        sleep 2
    done

    log "Timed out waiting for one clean Nginx Pod"

    kubectl -n "$NAMESPACE" get pods \
        -l "$LABEL_SELECTOR" -o wide || true

    return 1
}

observers_alive() {
    [[ -n "$HARNESS_PID" ]] &&
        kill -0 "$HARNESS_PID" 2>/dev/null || return 1

    [[ -n "$PROBE_PID" ]] &&
        kill -0 "$PROBE_PID" 2>/dev/null || return 1

    if [[ "$MODE" == failure-aware ]]; then
        [[ -n "$CONTROLLER_PID" ]] &&
            kill -0 "$CONTROLLER_PID" 2>/dev/null || return 1
    fi

    return 0
}

stop_observers() {
    local pid

    for pid in "$HARNESS_PID" "$PROBE_PID" "$CONTROLLER_PID"; do
        if [[ -n "$pid" ]]; then
            kill -INT "$pid" 2>/dev/null || true
        fi
    done

    sleep 2

    for pid in "$HARNESS_PID" "$PROBE_PID" "$CONTROLLER_PID"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done

    HARNESS_PID=""
    PROBE_PID=""
    CONTROLLER_PID=""
}

capture_harness() {
    [[ -f "$DIR/harness.log" ]] || return 1

    HARNESS_DIR="$(
        sed -n 's/^Output directory: //p' "$DIR/harness.log" |
        head -n 1
    )"

    [[ -n "$HARNESS_DIR" && -d "$HARNESS_DIR" ]] || return 1

    local file

    for file in \
        http-observations.csv \
        node-observations.csv \
        lease-observations.csv \
        pod-observations.csv \
        taint-observations.csv \
        event-observations.csv
    do
        if [[ -f "$HARNESS_DIR/$file" ]]; then
            cp "$HARNESS_DIR/$file" "$DIR/$file"
        fi
    done
}

cleanup() {
    local rc=$?

    trap - EXIT INT TERM

    stop_observers
    capture_harness || true

    if [[ "$SUCCESS" != true ]]; then
        log "Run incomplete; evidence retained: $DIR"

        if [[ "$VM_OFF" == true ]]; then
            log "WARNING: Worker1 may still be powered off"
        fi
    fi

    exit "$rc"
}

trap cleanup EXIT
trap 'fail "Interrupted by signal"' INT TERM

for value in \
    "$HOLD" \
    "$BOOT_TIMEOUT" \
    "$BASELINE" \
    "$POST_RETURN" \
    "$POD_WAIT" \
    "$FINAL_HTTP_WAIT" \
    "$FINAL_HTTP_STABLE"
do
    [[ "$value" =~ ^[0-9]+$ ]] ||
        fail "Invalid timing configuration"
done

(( HOLD >= 300 )) ||
    fail "Shutdown hold must be at least 300 seconds"

(( FINAL_HTTP_STABLE >= 1 )) ||
    fail "Stable HTTP success count must be positive"

log "Starting $MODE run-$RUN"

cat > "$DIR/configuration.json" <<EOF
{
  "scenario": "scenario-a",
  "arm": "$MODE",
  "run": "$RUN",
  "shutdown_method": "ssh-systemctl-poweroff",
  "shutdown_confirmation": "sustained-icmp-loss",
  "hypervisor_shutoff_verified": false,
  "vm_start_method": "manual-horizon",
  "hold_seconds": $HOLD,
  "baseline_seconds": $BASELINE,
  "post_return_seconds": $POST_RETURN,
  "pod_wait_seconds": $POD_WAIT,
  "final_http_wait_seconds": $FINAL_HTTP_WAIT,
  "final_http_stable_count": $FINAL_HTTP_STABLE,
  "http_interval_ms": 1000,
  "http_timeout_ms": 3000
}
EOF

# --------------------------------------------------
# 1. PRE-FLIGHT
# --------------------------------------------------

log "Checking workers and standalone service"

node_ready "$WORKER1_NODE" ||
    fail "Worker1 not Ready"

node_ready "$WORKER2_NODE" ||
    fail "Worker2 not Ready"

ping_ok ||
    fail "Worker1 ping unavailable"

ssh_ok ||
    fail "Worker1 SSH unavailable"

http_ok "http://${WORKER1_IP}:8081/" ||
    fail "Standalone Nginx unavailable"

# --------------------------------------------------
# 2. PREPARE NGINX
# --------------------------------------------------

log "Preparing Kubernetes Nginx"

kubectl -n "$NAMESPACE" scale deployment/baseline-web \
    --replicas=0 ||
    fail "Scale-down failed"

kubectl -n "$NAMESPACE" wait \
    --for=delete pod \
    -l "$LABEL_SELECTOR" \
    --timeout=180s ||
    fail "Old Pod did not terminate"

if [[ "$MODE" == native ]]; then
    kubectl apply -f "$NATIVE_MANIFEST" ||
        fail "Native manifest application failed"
else
    kubectl apply -f "$FA_MANIFEST" ||
        fail "Failure-Aware manifest application failed"
fi

kubectl -n "$NAMESPACE" patch deployment baseline-web \
    --type=merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":null}}}}}' ||
    fail "Placement selector cleanup failed"

kubectl -n "$NAMESPACE" annotate deployment baseline-web \
    failure-aware.io/placement-managed- \
    failure-aware.io/placement-candidate- \
    failure-aware.io/placement-original-hostname- \
    failure-aware.io/placement-cleanup- \
    --overwrite >/dev/null 2>&1 || true

kubectl -n "$NAMESPACE" scale deployment/baseline-web \
    --replicas=1 ||
    fail "Scale-up failed"

kubectl -n "$NAMESPACE" rollout status deployment/baseline-web \
    --timeout=180s ||
    fail "Rollout failed"

wait_clean_nginx "$DIR/pods-before.json" "$POD_WAIT" ||
    fail "Initial Nginx Pod did not reach clean state"

kubectl -n "$NAMESPACE" get deployment baseline-web \
    -o json > "$DIR/deployment-before.json"

python3 - "$DIR/pods-before.json" \
    "$DIR/deployment-before.json" \
    "$WORKER1_NODE" "$MODE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    pods = json.load(handle)["items"]

with open(sys.argv[2], encoding="utf-8") as handle:
    deployment = json.load(handle)

worker = sys.argv[3]
mode = sys.argv[4]

assert len(pods) == 1, "Expected exactly one Pod"

pod = pods[0]

assert pod["spec"]["nodeName"] == worker
assert pod["status"]["phase"] == "Running"
assert not pod["metadata"].get("deletionTimestamp")

assert any(
    c["type"] == "Ready"
    and c["status"] == "True"
    for c in pod["status"].get("conditions", [])
)

selector = (
    deployment["spec"]["template"]["spec"]
    .get("nodeSelector", {})
)

assert not selector.get("kubernetes.io/hostname"), (
    "Hard hostname selector remains"
)

tolerations = pod["spec"].get("tolerations", [])

for key in (
    "node.kubernetes.io/not-ready",
    "node.kubernetes.io/unreachable",
):
    matches = [
        t for t in tolerations
        if t.get("key") == key
        and t.get("effect") == "NoExecute"
    ]

    assert len(matches) == 1, (
        "Expected exactly one matching toleration: " + key
    )

    seconds = matches[0].get("tolerationSeconds")

    if mode == "native":
        assert seconds == 300, (
            "Native toleration must be 300 seconds"
        )
    else:
        assert seconds is None, (
            "FA1 toleration must not expire"
        )

print("INITIAL_WORKLOAD_VERIFIED")
print("ORIGINAL_POD", pod["metadata"]["name"])
print("ORIGINAL_UID", pod["metadata"]["uid"])
PY

ORIGINAL_POD="$(
    python3 - "$DIR/pods-before.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    pod = json.load(handle)["items"][0]

print(pod["metadata"]["name"])
PY
)"

ORIGINAL_UID="$(
    python3 - "$DIR/pods-before.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    pod = json.load(handle)["items"][0]

print(pod["metadata"]["uid"])
PY
)"

printf '%s\n' "$ORIGINAL_POD" > "$DIR/original-pod.txt"
printf '%s\n' "$ORIGINAL_UID" > "$DIR/original-uid.txt"

http_ok "http://${WORKER2_IP}:${NODEPORT}/" ||
    fail "Kubernetes Nginx unavailable"

# --------------------------------------------------
# 3. START OBSERVERS
# --------------------------------------------------

log "Starting measurement observers"

export FAILURE_AWARE_WORKLOAD_PROFILE=nginx

HARNESS_CONFIG="$ROOT/harness/config/scenario-a.json" \
    stdbuf -oL -eL "$HARNESS_BINARY" \
    > "$DIR/harness.log" 2>&1 &

HARNESS_PID=$!

python3 "$ROOT/scripts/scenario-a-http-probe.py" \
    --url "http://${WORKER1_IP}:8081/" \
    --expected-body "SCENARIO_A_STANDALONE_NGINX" \
    --interval 1 \
    --timeout 3 \
    --output "$DIR/single-node-http.csv" \
    > "$DIR/single-node-probe.log" 2>&1 &

PROBE_PID=$!

if [[ "$MODE" == failure-aware ]]; then
    (
        cd "$ROOT"

        FAILURE_AWARE_RECOVERY_VERIFY_URL="http://${WORKER2_IP}:${NODEPORT}/" \
            "$CONTROLLER_BINARY"

    ) > "$DIR/controller.log" 2>&1 &

    CONTROLLER_PID=$!
else
    echo "Native mode: controller disabled" \
        > "$DIR/controller.log"
fi

sleep "$BASELINE"

observers_alive ||
    fail "Observer or controller exited during baseline"

# --------------------------------------------------
# 4. SHUTDOWN WORKER1
# --------------------------------------------------

record "vm-stop-requested.txt"

log "Requesting SSH guest shutdown"

VM_OFF=true

timeout 15 ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$WORKER1_SSH" \
    'sudo -n systemctl poweroff' || true

failures=0
deadline=$((SECONDS + 120))

while (( SECONDS < deadline )); do
    if ping_ok; then
        failures=0
    else
        failures=$((failures + 1))
    fi

    if (( failures >= 3 )); then
        record "vm-ping-loss-confirmed.txt"
        break
    fi

    sleep 1
done

(( failures >= 3 )) ||
    fail "Sustained ping loss not observed"

log "Network-observed Worker1 loss verified"

# --------------------------------------------------
# 5. OFFLINE OBSERVATION WINDOW
# --------------------------------------------------

log "Holding Worker1 offline for ${HOLD}s"

hold_start=$SECONDS

while (( SECONDS - hold_start < HOLD )); do
    if ping_ok; then
        fail "Worker1 returned before hold completed"
    fi

    observers_alive ||
        fail "Observer or controller exited during hold"

    sleep 2
done

record "hold-completed.txt"

kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" \
    -o json > "$DIR/pods-before-restart.json" ||
    fail "Cannot capture pre-restart Pods"

log "Offline observation completed"

echo
echo "=========================================="
echo "START WORKER1 THROUGH OPENSTACK HORIZON"
echo "The runner will detect its return."
echo "=========================================="

# --------------------------------------------------
# 6. OBSERVE WORKER RETURN
# --------------------------------------------------

deadline=$((SECONDS + BOOT_TIMEOUT))

ping_returned=false
ssh_returned=false
ready_returned=false

while (( SECONDS < deadline )); do
    observers_alive ||
        fail "Observer or controller exited during VM return"

    if [[ "$ping_returned" == false ]] && ping_ok; then
        record "vm-ping-returned.txt"
        ping_returned=true
    fi

    if [[ "$ping_returned" == true &&
          "$ssh_returned" == false ]] && ssh_ok; then
        record "vm-ssh-returned.txt"
        ssh_returned=true
    fi

    if [[ "$ssh_returned" == true &&
          "$ready_returned" == false ]] &&
          node_ready "$WORKER1_NODE"; then
        record "worker1-ready-returned.txt"
        ready_returned=true
    fi

    if [[ "$ping_returned" == true &&
          "$ssh_returned" == true &&
          "$ready_returned" == true ]]; then
        break
    fi

    sleep 2
done

[[ "$ready_returned" == true ]] ||
    fail "Worker1 did not return before timeout"

VM_OFF=false

deadline=$((SECONDS + 120))

until http_ok "http://${WORKER1_IP}:8081/"; do
    (( SECONDS < deadline )) ||
        fail "Standalone Nginx did not return"

    sleep 2
done

record "standalone-restored.txt"

log "Observing post-return period for ${POST_RETURN}s"

sleep "$POST_RETURN"

observers_alive ||
    fail "Observer or controller exited during post-return period"

# --------------------------------------------------
# 7. PRESERVE EVIDENCE
# --------------------------------------------------

log "Stopping observers and preserving evidence"

stop_observers

capture_harness ||
    fail "Harness output directory unavailable"

for file in \
    http-observations.csv \
    node-observations.csv \
    pod-observations.csv
do
    [[ -s "$DIR/$file" ]] ||
        fail "Required evidence missing: $file"
done

[[ -s "$DIR/single-node-http.csv" ]] ||
    fail "Standalone HTTP evidence missing"

kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" \
    -o json > "$DIR/pods-after.json"

# --------------------------------------------------
# 8. CLASSIFY RECOVERY BEFORE CLEANUP
# --------------------------------------------------

python3 - "$DIR" "$ORIGINAL_POD" "$ORIGINAL_UID" \
    "$WORKER1_NODE" "$WORKER2_NODE" "$MODE" <<'PY'
import csv
import json
import sys
from datetime import datetime
from pathlib import Path

directory = Path(sys.argv[1])
original_name = sys.argv[2]
original_uid = sys.argv[3]
original_node = sys.argv[4]
candidate_node = sys.argv[5]
mode = sys.argv[6]


def parse_time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(
            value.strip().replace("Z", "+00:00")
        )
    except ValueError:
        return None


def read_time(name):
    path = directory / name
    if not path.exists():
        return None
    return parse_time(path.read_text())


def load_json(name):
    path = directory / name
    if not path.exists():
        return None
    return json.loads(path.read_text())


def valid_replacement(pod):
    metadata = pod.get("metadata", {})
    spec = pod.get("spec", {})
    status = pod.get("status", {})

    if metadata.get("uid") == original_uid:
        return False
    if metadata.get("name") == original_name:
        return False
    if metadata.get("deletionTimestamp"):
        return False
    if status.get("phase") != "Running":
        return False

    node = spec.get("nodeName", "")
    if not node or node == original_node:
        return False

    if mode == "failure-aware" and node != candidate_node:
        return False

    return True


snapshot = load_json("pods-before-restart.json")
ping_return = read_time("vm-ping-returned.txt")

pre_restart = []

if snapshot:
    for pod in snapshot.get("items", []):
        if valid_replacement(pod):
            pre_restart.append(pod)

with (directory / "pod-observations.csv").open(
    newline="", encoding="utf-8"
) as handle:
    rows = list(csv.DictReader(handle))

observations = []

for row in rows:
    pod_name = row.get("pod", "")
    node = row.get("node", "")
    phase = row.get("phase", "")
    deletion = row.get("deletion_timestamp", "")
    observed_at = parse_time(row.get("timestamp_utc", ""))

    if pod_name == original_name:
        continue
    if node == original_node or not node:
        continue
    if mode == "failure-aware" and node != candidate_node:
        continue
    if phase != "Running" or deletion:
        continue
    if observed_at is None:
        continue

    observations.append({
        "pod": pod_name,
        "node": node,
        "observed_at": observed_at,
    })

observations.sort(key=lambda x: x["observed_at"])

if pre_restart:
    selected = pre_restart[0]
    replacement_name = selected["metadata"]["name"]
    replacement_node = selected["spec"]["nodeName"]

    outcome = "RECOVERED_BEFORE_RESTART"

elif observations:
    first = observations[0]
    replacement_name = first["pod"]
    replacement_node = first["node"]

    if ping_return and first["observed_at"] < ping_return:
        outcome = "RECOVERED_BEFORE_PING_RETURN"
    else:
        outcome = "RECOVERED_AFTER_RESTART"

else:
    replacement_name = None
    replacement_node = None
    outcome = "NO_REPLACEMENT"

first_running = None

for observation in observations:
    if observation["pod"] == replacement_name:
        first_running = observation["observed_at"]
        break

result = {
    "outcome": outcome,
    "replacement_pod": replacement_name,
    "replacement_node": replacement_node,
    "replacement_running_observed_utc": (
        first_running.isoformat() if first_running else None
    ),
    "pre_restart_snapshot_verified": bool(pre_restart),
    "classification_reference": (
        "pre-restart Kubernetes Pod snapshot and "
        "harness Pod observations"
    )
}

(directory / "recovery-outcome.json").write_text(
    json.dumps(result, indent=2) + "\n"
)

print("RECOVERY_OUTCOME", outcome)
print("REPLACEMENT_POD", replacement_name)
print("REPLACEMENT_NODE", replacement_node)
PY

# --------------------------------------------------
# 9. RESET FOR NEXT RUN
# --------------------------------------------------

log "Restoring controlled starting placement"

kubectl -n "$NAMESPACE" scale deployment/baseline-web \
    --replicas=0 ||
    fail "Post-run scale-down failed"

kubectl -n "$NAMESPACE" wait \
    --for=delete pod \
    -l "$LABEL_SELECTOR" \
    --timeout=180s ||
    fail "Post-run Pod cleanup failed"

kubectl -n "$NAMESPACE" patch deployment baseline-web \
    --type=merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":null}}}}}' ||
    fail "Post-run placement cleanup failed"

kubectl -n "$NAMESPACE" annotate deployment baseline-web \
    failure-aware.io/placement-managed- \
    failure-aware.io/placement-candidate- \
    failure-aware.io/placement-original-hostname- \
    failure-aware.io/placement-cleanup- \
    --overwrite >/dev/null 2>&1 || true

kubectl -n "$NAMESPACE" scale deployment/baseline-web \
    --replicas=1 ||
    fail "Post-run scale-up failed"

kubectl -n "$NAMESPACE" rollout status deployment/baseline-web \
    --timeout=180s ||
    fail "Post-run rollout failed"

wait_clean_nginx "$DIR/pods-final.json" "$POD_WAIT" ||
    fail "Final Nginx Pod did not reach clean state"

# --------------------------------------------------
# 10. VERIFY FINAL HTTP STABILITY
# --------------------------------------------------

log "Verifying final service stability"

wait_stable_http \
    "http://${WORKER1_IP}:8081/" \
    "final-standalone-http" \
    "$FINAL_HTTP_WAIT" \
    "$FINAL_HTTP_STABLE" ||
    fail "Final standalone HTTP did not stabilize"

wait_stable_http \
    "http://${WORKER2_IP}:${NODEPORT}/" \
    "final-kubernetes-http" \
    "$FINAL_HTTP_WAIT" \
    "$FINAL_HTTP_STABLE" ||
    fail "Final Kubernetes HTTP did not stabilize"

node_ready "$WORKER1_NODE" ||
    fail "Worker1 not Ready after cleanup"

ssh_ok ||
    fail "Worker1 SSH unavailable after cleanup"

record "run-completed.txt"

rm -f "$DIR/INCOMPLETE"
touch "$DIR/COMPLETE"

SUCCESS=true

log "SCENARIO_A_RUN_COMPLETE $MODE $RUN"