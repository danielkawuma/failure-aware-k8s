#!/usr/bin/env bash
# OpenMRS C+D SSH-based reconciliation.
# Reboot original worker, verify old-writer retirement,
# and release NFS fence only after safety checks.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${OPENMRS_CD_AUTHORITY_FILE:?Set OPENMRS_CD_AUTHORITY_FILE}"

AUTHORITY_FILE="$(realpath "$OPENMRS_CD_AUTHORITY_FILE")"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
SSH_USER="${OPENMRS_CD_SSH_USER:-ubuntu}"

NS="${OPENMRS_CD_NAMESPACE:-openmrs37}"
DEP="${OPENMRS_CD_DEPLOYMENT:-openmrs-mariadb}"
SEL="${OPENMRS_CD_SELECTOR:-app=openmrs-mariadb}"

VERIFY="$ROOT/scripts/openmrs-cd-sql-verify.sh"
FENCE="$ROOT/scripts/openmrs-cd-fence-original.sh"

REBOOT_WAIT="${OPENMRS_CD_REBOOT_WAIT_SECONDS:-600}"
RUNTIME_WAIT="${OPENMRS_CD_RUNTIME_WAIT_SECONDS:-240}"
SANDBOX_WAIT="${OPENMRS_CD_SANDBOX_WAIT_SECONDS:-180}"
STABILITY="${OPENMRS_CD_STABILITY_SECONDS:-30}"
POLL="${OPENMRS_CD_POLL_SECONDS:-5}"

EVIDENCE="${OPENMRS_CD_RECONCILE_EVIDENCE_DIR:-$(dirname "$AUTHORITY_FILE")/reconciliation-ssh}"
mkdir -p "$EVIDENCE"

STATE="$EVIDENCE/state.txt"
OUTCOME="$EVIDENCE/outcome.txt"
BOOT_BEFORE="$EVIDENCE/boot-before.txt"
BOOT_AFTER="$EVIDENCE/boot-after.txt"

exec > >(tee -a "$EVIDENCE/reconciliation.log") 2>&1

log() {
    printf '[RECONCILE] %s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

atomic_write() {
    local file="$1" value="$2" temp
    temp="$(mktemp "$EVIDENCE/.state.XXXXXX")"
    printf '%s\n' "$value" > "$temp"
    mv -f "$temp" "$file"
}

save_state() {
    atomic_write "$STATE" "$1"
    log "STATE=$1"
}

fail() {
    log "BLOCKED: $*"
    atomic_write "$OUTCOME" BLOCKED
    exit 1
}

[[ -r "$AUTHORITY_FILE" ]] || fail "Authority unavailable"
[[ -r "$SSH_KEY" ]] || fail "SSH key unavailable"
[[ -x "$VERIFY" && -x "$FENCE" ]] ||
    fail "Required helper missing"

read -r ORIGINAL ORIGINAL_IP CANDIDATE ORIGINAL_POD < <(
    python3 - "$AUTHORITY_FILE" <<'PY'
import json,sys
a=json.load(open(sys.argv[1]))
print(a["node"],a["ip"],a["candidate"],a["pod"])
PY
)

[[ "$ORIGINAL" =~ ^k3s-worker[0-9]+$ ]] ||
    fail "Invalid original node"

[[ "$CANDIDATE" =~ ^k3s-worker[0-9]+$ ]] ||
    fail "Invalid candidate node"

[[ "$ORIGINAL" != "$CANDIDATE" ]] ||
    fail "Original equals candidate"

[[ "$ORIGINAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Invalid original IP"

export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL"
export OPENMRS_CD_ORIGINAL_IP="$ORIGINAL_IP"

remote() {
    timeout 45 ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "$SSH_USER@$ORIGINAL_IP" "$@"
}

fence_status() {
    "$FENCE" status 2>&1
}

fence_active() {
    local output rc=0
    output="$(fence_status)" || rc=$?
    [[ "$rc" -eq 0 ]] &&
        grep -qx FENCED <<< "$output"
}

fence_inactive() {
    local output rc=0
    output="$(fence_status)" || rc=$?
    [[ "$rc" -eq 1 ]] &&
        grep -qx NOT_FENCED <<< "$output"
}

verify_authority() {
    kubectl --request-timeout=10s \
        -n "$NS" get deployment "$DEP" -o json |
        python3 -c '
import json,sys
d=json.load(sys.stdin)["spec"]
assert d.get("replicas")==1
assert d["template"]["spec"].get(
    "nodeSelector",{}
).get("kubernetes.io/hostname")==sys.argv[1]
' "$CANDIDATE" || return 1

    kubectl --request-timeout=10s \
        -n "$NS" get pods -l "$SEL" -o json |
        python3 -c '
import json,sys
pods=json.load(sys.stdin)["items"]
assert len(pods)==1
p=pods[0]
assert p["spec"]["nodeName"]==sys.argv[1]
assert p["status"]["phase"]=="Running"
assert not p["metadata"].get("deletionTimestamp")
assert any(
    c["type"]=="Ready" and c["status"]=="True"
    for c in p["status"].get("conditions",[])
)
' "$CANDIDATE" || return 1

    # Structured lookup: an absent Pod is an empty item list.
    kubectl --request-timeout=10s \
        -n "$NS" get pods \
        --field-selector "metadata.name=$ORIGINAL_POD" \
        -o json |
        python3 -c '
import json,sys
assert len(json.load(sys.stdin)["items"])==0
'
}

verify_sql() {
    OPENMRS_CD_AUTHORITY_FILE="$AUTHORITY_FILE" \
        timeout 45 "$VERIFY"
}

get_boot_id() {
    remote 'cat /proc/sys/kernel/random/boot_id'
}

runtime_ready() {
    remote 'sudo -n bash -s' <<'REMOTE'
set -Eeuo pipefail
systemctl is-active --quiet k3s-agent
test -S /run/k3s/containerd/containerd.sock
timeout 15 k3s crictl info >/dev/null
echo RUNTIME_READY
REMOTE
}

wait_runtime() {
    local deadline=$((SECONDS + RUNTIME_WAIT))

    while (( SECONDS < deadline )); do
        if runtime_ready; then
            log RUNTIME_READY
            return 0
        fi
        sleep "$POLL"
    done
    return 1
}

verify_old_writer_absent() {
    remote "sudo -n bash -s -- '$NS' '$DEP'" <<'REMOTE'
set -Eeuo pipefail
NS="$1"
DEP="$2"

containers="$(timeout 20 k3s crictl ps -a -o json)"
sandboxes="$(timeout 20 k3s crictl pods -o json)"

python3 - "$NS" "$DEP" "$containers" "$sandboxes" <<'PY'
import json,sys

ns,dep=sys.argv[1:3]
containers=json.loads(sys.argv[3])
sandboxes=json.loads(sys.argv[4])

def matches(labels):
    return (
        labels.get("io.kubernetes.pod.namespace")==ns
        and labels.get("io.kubernetes.pod.name","").startswith(dep+"-")
    )

for c in containers.get("containers",[]):
    labels=c.get("labels",{})
    if matches(labels) and labels.get(
        "io.kubernetes.container.name"
    )=="mariadb":
        if c.get("state")=="CONTAINER_RUNNING":
            raise SystemExit("OLD_CONTAINER_RUNNING")

for p in sandboxes.get("items",[]):
    if matches(p.get("labels",{})):
        raise SystemExit("OLD_SANDBOX_PRESENT")

print("NO_OLD_CONTAINER_OR_SANDBOX")
PY

# A remaining MariaDB process is not acceptable.
# This node is the original experimental worker.
if ps -eo comm= |
   grep -Eq '^(mariadbd|mysqld|mariadb-admin)$'; then
    echo OLD_DATABASE_PROCESS_PRESENT
    exit 1
fi

echo OLD_WRITER_ABSENT
REMOTE
}

wait_old_writer_absent() {
    local deadline=$((SECONDS + SANDBOX_WAIT))

    while (( SECONDS < deadline )); do
        if verify_old_writer_absent; then
            return 0
        fi
        sleep "$POLL"
    done
    return 1
}

verify_all() {
    verify_old_writer_absent &&
    verify_authority &&
    verify_sql
}

restore_fence() {
    log "CRITICAL: Restoring storage fence"
    "$FENCE" fence || return 1
    fence_active
}

CURRENT_STATE=NEW
[[ -f "$STATE" ]] &&
    CURRENT_STATE="$(cat "$STATE")"

log "Original=$ORIGINAL Candidate=$CANDIDATE"
log "Previous state=$CURRENT_STATE"

# Completed reconciliation must be idempotent.
if [[ "$CURRENT_STATE" == RECONCILIATION_VERIFIED ]]; then
    if fence_inactive &&
       runtime_ready &&
       verify_all; then
        atomic_write "$OUTCOME" RECONCILIATION_VERIFIED
        log "RECONCILIATION_VERIFIED (already completed)"
        exit 0
    fi

    fail "Completed checkpoint no longer passes safety verification"
fi

[[ "${OPENMRS_CD_ALLOW_SSH_REBOOT:-false}" == true ]] ||
    fail "OPENMRS_CD_ALLOW_SSH_REBOOT=true required"

[[ "${OPENMRS_CD_ALLOW_UNFENCE:-false}" == true ]] ||
    fail "OPENMRS_CD_ALLOW_UNFENCE=true required"

# An interrupted fence-release state is not restarted blindly.
if [[ "$CURRENT_STATE" == FENCE_RELEASED ]]; then
    if fence_inactive &&
       runtime_ready &&
       verify_all; then
        log "Resuming post-release verification"
    else
        fail "Interrupted fence release requires investigation"
    fi
else
    fence_active || fail "Active NFS fence not verified"
    verify_authority || fail "Replacement authority invalid"
    verify_sql || fail "Authenticated SQL failed"

    kubectl cordon "$ORIGINAL" ||
        fail "Cannot cordon original worker"

    case "$CURRENT_STATE" in
        REBOOT_VERIFIED|RUNTIME_READY|OLD_WRITER_ABSENT)
            [[ -s "$BOOT_BEFORE" && -s "$BOOT_AFTER" ]] ||
                fail "Reboot checkpoint incomplete"

            before="$(cat "$BOOT_BEFORE")"
            after="$(cat "$BOOT_AFTER")"
            current="$(get_boot_id)" ||
                fail "Cannot read current boot ID"

            [[ "$before" != "$after" &&
               "$current" == "$after" ]] ||
                fail "Reboot checkpoint mismatch"
            ;;

        REBOOT_REQUESTED)
            [[ -s "$BOOT_BEFORE" ]] ||
                fail "Missing pre-reboot boot ID"

            before="$(cat "$BOOT_BEFORE")"
            current="$(get_boot_id 2>/dev/null)" || current=""

            [[ -n "$current" && "$current" != "$before" ]] ||
                fail "Reboot not yet independently verified"

            atomic_write "$BOOT_AFTER" "$current"
            save_state REBOOT_VERIFIED
            ;;

        NEW)
            before="$(get_boot_id)" ||
                fail "Cannot obtain original boot ID"

            [[ -n "$before" ]] || fail "Empty boot ID"

            atomic_write "$BOOT_BEFORE" "$before"

            fence_active || fail "Fence changed before reboot"
            verify_authority || fail "Authority changed"

            save_state REBOOT_REQUESTED
            log "Initiating SSH reboot"

            remote 'sudo -n systemctl reboot' || true

            deadline=$((SECONDS + REBOOT_WAIT))
            after=""

            while (( SECONDS < deadline )); do
                after="$(get_boot_id 2>/dev/null)" || after=""

                if [[ -n "$after" && "$after" != "$before" ]]; then
                    break
                fi
                sleep "$POLL"
            done

            [[ -n "$after" && "$after" != "$before" ]] ||
                fail "Reboot not verified"

            atomic_write "$BOOT_AFTER" "$after"
            save_state REBOOT_VERIFIED
            ;;

        *)
            fail "Unknown checkpoint: $CURRENT_STATE"
            ;;
    esac

    wait_runtime ||
        fail "K3s/containerd not ready"

    save_state RUNTIME_READY

    wait_old_writer_absent ||
        fail "Old writer or sandbox remains"

    verify_authority ||
        fail "Replacement authority changed"

    verify_sql ||
        fail "SQL verification failed"

    fence_active ||
        fail "Fence lost before release"

    save_state OLD_WRITER_ABSENT

    verify_all ||
        fail "Final pre-release verification failed"

    log "Releasing NFS fence"

    "$FENCE" unfence ||
        fail "Fence release command failed"

    save_state FENCE_RELEASED
fi

if ! fence_inactive; then
    restore_fence || log "CRITICAL: Fence restoration failed"
    fail "Fence release not verified"
fi

if ! verify_all; then
    restore_fence || log "CRITICAL: Fence restoration failed"
    fail "Post-release safety verification failed"
fi

log "Monitoring post-release stability"

deadline=$((SECONDS + STABILITY))

while (( SECONDS < deadline )); do
    sleep "$POLL"

    if ! verify_all || ! fence_inactive; then
        restore_fence || log "CRITICAL: Fence restoration failed"
        fail "Post-release stability verification failed"
    fi
done

save_state RECONCILIATION_VERIFIED
atomic_write "$OUTCOME" RECONCILIATION_VERIFIED

log RECONCILIATION_VERIFIED
log "Original worker remains cordoned pending reset"