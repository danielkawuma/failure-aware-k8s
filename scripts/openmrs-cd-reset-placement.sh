#!/usr/bin/env bash
# OpenMRS Scenario C+D - controlled MariaDB placement reset.
#
# Original worker: k3s-worker3
# Recovery candidate: k3s-worker2
#
# This script:
#   1. Verifies node readiness and inactive NFS fences.
#   2. Captures the active MariaDB writer's identity.
#   3. Checks the destination worker for old database runtimes.
#   4. Scales the experimental MariaDB to zero.
#   5. Verifies old container and process retirement.
#   6. Rechecks destination runtime and storage fences.
#   7. Restores flexible placement, preferring Worker3.
#   8. Verifies one Ready MariaDB on Worker3.
#
# The separate "openmrs" namespace is not modified.
#
# Safety:
#   Fail closed on ambiguous container, process, sandbox,
#   node, or fence state.
#
# This is experimental runtime-based retirement verification.
# It does not implement externally enforced writer epochs.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NS="${OPENMRS_CD_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_CD_DEPLOYMENT:-openmrs-mariadb}"
SEL="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"

ORIGINAL="${OPENMRS_CD_ORIGINAL_NODE:-k3s-worker3}"
CANDIDATE="${OPENMRS_CD_CANDIDATE_NODE:-k3s-worker2}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
SSH_USER="${OPENMRS_CD_SSH_USER:-ubuntu}"

RETIRE_WAIT="${OPENMRS_CD_RETIRE_WAIT_SECONDS:-180}"
POLL="${OPENMRS_CD_POLL_SECONDS:-5}"
RESET_TIMEOUT="${OPENMRS_CD_RESET_TIMEOUT:-1200}"

BASE="$ROOT/experiments/evaluation/openmrs/scenario-c-d"
DIR="$BASE/reset-$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$DIR"

exec > >(tee -a "$DIR/reset.log") 2>&1

log() {
    printf '[RESET] %s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

fail() {
    log "BLOCKED: $*"
    printf 'BLOCKED\n' > "$DIR/outcome.txt"
    exit 1
}

[[ "${OPENMRS_CD_ALLOW_DB_RESTART:-false}" == true ]] ||
    fail "OPENMRS_CD_ALLOW_DB_RESTART=true required"

[[ "$NS" == "openmrs37" ]] ||
    fail "Unexpected namespace"

[[ "$DEP" == "openmrs-mariadb" ]] ||
    fail "Unexpected deployment"

[[ "$SEL" == "app=openmrs-mariadb" ]] ||
    fail "Unexpected selector"

[[ "$ORIGINAL" == "k3s-worker3" ]] ||
    fail "Unexpected original worker"

[[ "$CANDIDATE" == "k3s-worker2" ]] ||
    fail "Unexpected candidate worker"

[[ -r "$SSH_KEY" ]] ||
    fail "SSH key unavailable"

for value in "$RETIRE_WAIT" "$POLL" "$RESET_TIMEOUT"; do
    [[ "$value" =~ ^[0-9]+$ ]] ||
        fail "Invalid numeric configuration"

    (( value > 0 )) ||
        fail "Timeout must be positive"
done

for command in kubectl python3 ssh timeout; do
    command -v "$command" >/dev/null ||
        fail "Missing command: $command"
done

node_ip() {
    kubectl get node "$1" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

node_ready() {
    kubectl get node "$1" -o json |
        python3 -c '
import json
import sys

node = json.load(sys.stdin)

assert not node["spec"].get("unschedulable", False)

assert any(
    c["type"] == "Ready" and c["status"] == "True"
    for c in node["status"].get("conditions", [])
)
'
}

remote() {
    local ip="$1"
    shift

    timeout 60 ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "$SSH_USER@$ip" "$@"
}

fence_inactive() {
    local node="$1"
    local ip="$2"
    local output
    local rc=0

    output="$(
        FAILURE_AWARE_FENCE_MODE=nfs \
        FAILURE_AWARE_FENCE_WORKER_IP="$ip" \
        FAILURE_AWARE_FENCE_WORKLOAD_NODE="$node" \
        "$ROOT/scripts/storage-fence.sh" status 2>&1
    )" || rc=$?

    [[ "$rc" -eq 1 ]] &&
        grep -qx NOT_FENCED <<< "$output" &&
        ! grep -Eqi 'unknown|timeout|unverified' <<< "$output"
}

# Execute a read-only runtime audit on a worker.
#
# Modes:
#   capture - require exactly one active experimental MariaDB,
#             then emit its identity.
#   absent  - require no experimental MariaDB runtime.
#
# The audit uses CRI and /proc. It does not terminate processes.
#
# Worker3 is additionally required to have no MariaDB processes.
#
# The captured Pod UID and container ID allow subsequent checks
# to identify the previous writer even after CRI cleanup.

runtime_audit() {
    local ip="$1"
    local mode="$2"
    local worker="$3"
    local identity="${4:-}"

    remote "$ip" \
        "sudo -n bash -s -- '$NS' '$DEP' '$mode' '$worker' '$identity'" <<'REMOTE'
set -Eeuo pipefail

NS="$1"
DEP="$2"
MODE="$3"
WORKER="$4"
IDENTITY="$5"

systemctl is-active --quiet k3s-agent
test -S /run/k3s/containerd/containerd.sock

timeout 15 k3s crictl info >/dev/null

CONTAINERS="$(timeout 20 k3s crictl ps -a -o json)"
SANDBOXES="$(timeout 20 k3s crictl pods -o json)"

export CONTAINERS SANDBOXES

python3 - "$NS" "$DEP" "$MODE" "$WORKER" "$IDENTITY" <<'PY'
import json
import os
import pathlib
import sys

namespace, deployment, mode, worker, identity = sys.argv[1:]

containers = json.loads(os.environ["CONTAINERS"])
sandboxes = json.loads(os.environ["SANDBOXES"])

def matching(labels):
    return (
        labels.get("io.kubernetes.pod.namespace") == namespace
        and labels.get(
            "io.kubernetes.pod.name", ""
        ).startswith(deployment + "-")
    )

experimental_containers = [
    c for c in containers.get("containers", [])
    if matching(c.get("labels", {}))
    and c.get("labels", {}).get(
        "io.kubernetes.container.name"
    ) == "mariadb"
]

active_containers = [
    c for c in experimental_containers
    if c.get("state") == "CONTAINER_RUNNING"
]

experimental_sandboxes = [
    p for p in sandboxes.get("items", [])
    if matching(p.get("labels", {}))
]

def process_snapshot():
    result = []

    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue

        try:
            cgroup = (entry / "cgroup").read_text()
            stat = (entry / "stat").read_text()
            comm = (entry / "comm").read_text().strip()
        except (OSError, ProcessLookupError):
            continue

        parts = stat.rsplit(")", 1)

        state = (
            parts[1].strip().split()[0]
            if len(parts) == 2
            else "?"
        )

        result.append({
            "pid": entry.name,
            "state": state,
            "comm": comm,
            "cgroup": cgroup,
        })

    return result

processes = process_snapshot()

if mode == "capture":
    if len(active_containers) != 1:
        raise SystemExit("EXPECTED_ONE_ACTIVE_EXPERIMENTAL_CONTAINER")

    container = active_containers[0]

    labels = container.get("labels", {})
    pod_uid = labels.get("io.kubernetes.pod.uid", "")

    if not pod_uid:
        raise SystemExit("POD_UID_NOT_AVAILABLE")

    container_id = container.get("id", "")

    if not container_id:
        raise SystemExit("CONTAINER_ID_NOT_AVAILABLE")

    matching_processes = [
        p for p in processes
        if container_id in p["cgroup"]
        and p["comm"] in ("mariadbd", "mysqld")
        and p["state"] != "Z"
    ]

    if len(matching_processes) != 1:
        raise SystemExit("EXPECTED_ONE_DATABASE_SERVER_PROCESS")

    writer = matching_processes[0]

    print(json.dumps({
        "pod_uid": pod_uid,
        "container_id": container_id,
        "pid": int(writer["pid"]),
        "cgroup": writer["cgroup"].strip(),
    }))

    sys.exit(0)

if mode != "absent":
    raise SystemExit("INVALID_AUDIT_MODE")

if active_containers:
    raise SystemExit("EXPERIMENTAL_CONTAINER_RUNNING")

if experimental_sandboxes:
    raise SystemExit("EXPERIMENTAL_SANDBOX_REMAINS")

# All known experimental Pod UIDs and container IDs.
pod_tokens = set()
container_tokens = set()

for c in experimental_containers:
    labels = c.get("labels", {})
    uid = labels.get("io.kubernetes.pod.uid", "")

    if uid:
        pod_tokens.add(uid.replace("-", "_"))

    if c.get("id"):
        container_tokens.add(c["id"])

for p in experimental_sandboxes:
    uid = p.get("metadata", {}).get("uid", "")

    if uid:
        pod_tokens.add(uid.replace("-", "_"))

# Add the identity captured before shutdown.
if identity:
    previous = json.loads(identity)

    pod_tokens.add(
        previous["pod_uid"].replace("-", "_")
    )

    container_tokens.add(
        previous["container_id"]
    )

    recorded_pid = previous["pid"]
    recorded_cgroup = previous["cgroup"]

    for p in processes:
        if int(p["pid"]) == recorded_pid:
            if p["cgroup"].strip() == recorded_cgroup:
                if p["state"] != "Z":
                    raise SystemExit("RECORDED_WRITER_PROCESS_STILL_ACTIVE")

for p in processes:
    if p["state"] == "Z":
        continue

    if any(
        token in p["cgroup"]
        for token in pod_tokens
    ):
        raise SystemExit(
            "EXPERIMENTAL_POD_PROCESS_REMAINS_PID_" + p["pid"]
        )

    if any(
        token in p["cgroup"]
        for token in container_tokens
    ):
        raise SystemExit(
            "EXPERIMENTAL_CONTAINER_PROCESS_REMAINS_PID_" + p["pid"]
        )

# Worker3 is reserved for the experiment.
# Reject any MariaDB process there before relocation.
if worker == "k3s-worker3":
    for p in processes:
        if (
            p["comm"] in ("mariadbd", "mysqld", "mariadb-admin")
            and p["state"] != "Z"
        ):
            raise SystemExit("DATABASE_PROCESS_ON_WORKER3")

print("RUNTIME_RETIRED")
PY
REMOTE
}

wait_runtime_absent() {
    local ip="$1"
    local worker="$2"
    local identity="$3"
    local deadline=$((SECONDS + RETIRE_WAIT))

    while (( SECONDS < deadline )); do
        if runtime_audit "$ip" absent "$worker" "$identity"; then
            return 0
        fi

        sleep "$POLL"
    done

    return 1
}

ORIGINAL_IP="$(node_ip "$ORIGINAL")" ||
    fail "Original worker IP unavailable"

CANDIDATE_IP="$(node_ip "$CANDIDATE")" ||
    fail "Candidate worker IP unavailable"

[[ -n "$ORIGINAL_IP" && -n "$CANDIDATE_IP" ]] ||
    fail "Worker IP missing"

node_ready "$ORIGINAL" ||
    fail "Original worker not Ready and schedulable"

node_ready "$CANDIDATE" ||
    fail "Candidate worker not Ready and schedulable"

fence_inactive "$ORIGINAL" "$ORIGINAL_IP" ||
    fail "Original worker fence not inactive"

fence_inactive "$CANDIDATE" "$CANDIDATE_IP" ||
    fail "Candidate worker fence not inactive"

kubectl -n "$NS" get deployment "$DEP" -o yaml \
    > "$DIR/deployment-before.yaml"

kubectl -n "$NS" get pods -l "$SEL" -o json \
    > "$DIR/pods-before.json"

read -r CURRENT POD_UID < <(
    python3 - "$DIR/pods-before.json" <<'PY'
import json
import sys

pods = json.load(open(sys.argv[1]))["items"]

assert len(pods) == 1

pod = pods[0]

assert pod["status"]["phase"] == "Running"
assert not pod["metadata"].get("deletionTimestamp")

assert any(
    c["type"] == "Ready" and c["status"] == "True"
    for c in pod["status"].get("conditions", [])
)

print(
    pod["spec"]["nodeName"],
    pod["metadata"]["uid"]
)
PY
) || fail "Current database identity unavailable"

[[ "$CURRENT" == "$ORIGINAL" ||
   "$CURRENT" == "$CANDIDATE" ]] ||
    fail "Database on unexpected worker"

CURRENT_IP="$(node_ip "$CURRENT")"

log "Current=$CURRENT Original=$ORIGINAL Candidate=$CANDIDATE"

# Capture the exact current writer identity.
runtime_audit "$CURRENT_IP" capture "$CURRENT" \
    > "$DIR/writer-identity.json" ||
    fail "Cannot capture current writer identity"

python3 -m json.tool "$DIR/writer-identity.json" \
    > "$DIR/writer-identity-pretty.json" ||
    fail "Invalid captured writer identity"

cat "$DIR/writer-identity-pretty.json"

IDENTITY="$(cat "$DIR/writer-identity.json")"

# Cross-check Pod UID against the Kubernetes API.
python3 - "$DIR/writer-identity.json" "$POD_UID" <<'PY'
import json
import sys

identity = json.load(open(sys.argv[1]))

assert identity["pod_uid"] == sys.argv[2], \
    "Captured runtime does not match Kubernetes Pod UID"
PY

# Destination must be clear before stopping the writer.
if [[ "$CURRENT" != "$ORIGINAL" ]]; then
    runtime_audit "$ORIGINAL_IP" absent "$ORIGINAL" \
        > "$DIR/destination-before.txt" ||
        fail "Destination worker contains unresolved runtime"
fi

log "Scaling experimental MariaDB to zero"

kubectl -n "$NS" scale deployment "$DEP" --replicas=0 ||
    fail "Scale-down failed"

kubectl -n "$NS" wait \
    --for=delete pod \
    -l "$SEL" \
    --timeout=300s ||
    fail "Kubernetes Pod deletion not verified"

log "Waiting for previous writer retirement"

wait_runtime_absent "$CURRENT_IP" "$CURRENT" "$IDENTITY" \
    > "$DIR/runtime-after.txt" 2>&1 ||
    fail "Previous writer runtime not retired"

cat "$DIR/runtime-after.txt"

# Recheck the destination independently.
runtime_audit "$ORIGINAL_IP" absent "$ORIGINAL" \
    > "$DIR/destination-after.txt" ||
    fail "Destination worker no longer clear"

# Ensure Kubernetes has not created another experimental Pod.
kubectl -n "$NS" get pods -l "$SEL" -o json |
    python3 -c '
import json
import sys

assert len(json.load(sys.stdin)["items"]) == 0
' || fail "Unexpected experimental Pod exists"

# Verify both fences remain inactive.
fence_inactive "$ORIGINAL" "$ORIGINAL_IP" ||
    fail "Original worker fence changed"

fence_inactive "$CANDIDATE" "$CANDIDATE_IP" ||
    fail "Candidate worker fence changed"

# Flexible placement: both workers eligible, Worker3 preferred.
python3 - "$ORIGINAL" "$CANDIDATE" \
    > "$DIR/patch.json" <<'PY'
import json
import sys

original, candidate = sys.argv[1:3]

patch = {
    "spec": {
        "template": {
            "spec": {
                "nodeSelector": {
                    "kubernetes.io/hostname": None
                },
                "affinity": {
                    "nodeAffinity": {
                        "requiredDuringSchedulingIgnoredDuringExecution": {
                            "nodeSelectorTerms": [{
                                "matchExpressions": [{
                                    "key": "kubernetes.io/hostname",
                                    "operator": "In",
                                    "values": [original, candidate]
                                }]
                            }]
                        },
                        "preferredDuringSchedulingIgnoredDuringExecution": [{
                            "weight": 100,
                            "preference": {
                                "matchExpressions": [{
                                    "key": "kubernetes.io/hostname",
                                    "operator": "In",
                                    "values": [original]
                                }]
                            }
                        }]
                    }
                }
            }
        }
    }
}

print(json.dumps(patch))
PY

kubectl -n "$NS" patch deployment "$DEP" \
    --type=merge \
    -p "$(cat "$DIR/patch.json")" ||
    fail "Placement patch failed"

kubectl -n "$NS" scale deployment "$DEP" --replicas=1 ||
    fail "Scale-up failed"

kubectl -n "$NS" rollout status deployment/"$DEP" \
    --timeout="${RESET_TIMEOUT}s" ||
    fail "MariaDB rollout failed"

kubectl -n "$NS" get pods -l "$SEL" -o json \
    > "$DIR/pods-after.json"

python3 - "$DIR/pods-after.json" "$ORIGINAL" <<'PY'
import json
import sys

pods = json.load(open(sys.argv[1]))["items"]

assert len(pods) == 1

pod = pods[0]

assert pod["spec"]["nodeName"] == sys.argv[2]
assert pod["status"]["phase"] == "Running"
assert not pod["metadata"].get("deletionTimestamp")

assert any(
    c["type"] == "Ready" and c["status"] == "True"
    for c in pod["status"].get("conditions", [])
)

print(
    "RESET_READY",
    pod["metadata"]["name"],
    pod["spec"]["nodeName"]
)
PY

HOST_SELECTOR="$(
    kubectl -n "$NS" get deployment "$DEP" \
        -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}'
)"

[[ -z "$HOST_SELECTOR" ]] ||
    fail "Hard hostname selector remains"

printf 'RESET_READY\n' > "$DIR/outcome.txt"

log "Placement reset complete. Evidence: $DIR"