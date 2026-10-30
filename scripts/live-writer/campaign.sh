#!/usr/bin/env bash
# ============================================================
# Live-writer fencing campaign (H3, docs/hypotheses-midterm2.md)
#
# Each run uses a fresh copy of the baseline MariaDB datadir on the
# experimental NFS server (Worker3). A writer next to the original
# MariaDB on Worker1 inserts one numbered row every 0.2 s. Worker1 is
# then cut off from the API server (Scenario B rule) while its storage
# path stays open, which is the case in which a stale writer can keep
# committing.
#
#   fenced     At suspicion (Ready=Unknown) the NFS server drops Worker1's
#              TCP 2049 traffic. A replacement MariaDB with its own writer
#              is started on Worker2. After the partition heals, Worker1 is
#              rebooted to retire the original process, and only then is the
#              fence removed.
#   unfenced   No fence. At suspicion + 10 s, the point at which a 10-s
#              toleration would release the Pod, a replacement MariaDB is
#              started on Worker2 against the same datadir, as native
#              recovery would do.
#
# No SSH to Worker1 is used between the start of the partition and the
# end of the fault phase. Afterwards a verifier MariaDB on Worker2 reads
# every committed row; commits by the original writer after the fence
# are counted from the database itself.
#
# Usage:
#   SSH_KEY=~/.ssh/<key> scripts/live-writer/campaign.sh run
#   scripts/live-writer/campaign.sh status
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../experiment-config.sh"

FAULT="${SCRIPT_DIR}/../fault.sh"
NS="failure-aware-writer-test"
IMAGE="mariadb:10.11.19"
WORKER3_IP="${WORKER3_IP:-102.34.160.36}"
WORKER3_SSH="ubuntu@${WORKER3_IP}"
NFS_ROOT="/srv/failure-aware/concurrent-writer/database"
BASELINE_DATADIR="${NFS_ROOT}/baseline-001"
FENCE_HELPER="/usr/local/sbin/fa-writer-fence-w2"

RUNS_PER_ARM="${RUNS_PER_ARM:-10}"
LW_ARMS="${LW_ARMS:-fenced unfenced}"
POST_FENCE_SECONDS="${POST_FENCE_SECONDS:-120}"
UNFENCED_FAULT_SECONDS="${UNFENCED_FAULT_SECONDS:-180}"
REPLACEMENT_WAIT_SECONDS="${REPLACEMENT_WAIT_SECONDS:-240}"

ROOT_DIR="${REPO_ROOT}/experiments/evaluation/live-writer"
CURRENT_LINK="${ROOT_DIR}/CURRENT"

log() { printf '[LIVE-WRITER %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
utc_now() { date -u +"%Y-%m-%dT%H:%M:%S.%6NZ"; }
ssh3() { ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 "${WORKER3_SSH}" "$@"; }
ssh1() { ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 "${WORKER1_SSH}" "$@"; }

campaign_dir() {
    if [[ -L "${CURRENT_LINK}" ]]; then
        readlink -f "${CURRENT_LINK}"
        return
    fi
    local id dir seed
    id="campaign-$(date -u +%Y%m%dT%H%M%SZ)"
    dir="${ROOT_DIR}/${id}"
    seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"
    mkdir -p "${dir}"
    echo "${seed}" > "${dir}/seed.txt"
    ln -s "${id}" "${CURRENT_LINK}"
    python3 - "${dir}" "${seed}" "${RUNS_PER_ARM}" "${LW_ARMS}" <<'PY'
import csv, random, sys
d, seed, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
arms = sys.argv[4].split()
rows = [(arm, i) for arm in arms for i in range(1, n + 1)]
random.Random(seed).shuffle(rows)
with open(f"{d}/plan.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["order", "run_id", "arm"])
    for k, (arm, i) in enumerate(rows, 1):
        w.writerow([k, f"r{k:03d}-{arm}", arm])
PY
    {
        echo "campaign_id=${id}"
        echo "created_utc=$(utc_now)"
        echo "seed=${seed}"
        echo "git_commit=$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        echo "arms=${LW_ARMS}"
        echo "runs_per_arm=${RUNS_PER_ARM}"
        echo "post_fence_seconds=${POST_FENCE_SECONDS}"
        echo "unfenced_fault_seconds=${UNFENCED_FAULT_SECONDS}"
    } > "${dir}/campaign.env"
    log "Created ${dir} with seed ${seed}" >&2
    echo "${dir}"
}

# ------------------------------------------------------------
# Safety preflight: refuses to start while any earlier writer
# experiment could still hold the database or the fence.
# ------------------------------------------------------------
preflight() {
    local dir="$1"
    log "Preflight"
    {
        echo "utc=$(utc_now)"
        echo "--- pods in ${NS}"
        kubectl -n "${NS}" get pods -o wide 2>&1 || true
        echo "--- fence status on Worker3"
        ssh3 "sudo -n ${FENCE_HELPER} status" 2>&1 || true
        echo "--- mariadbd on Worker1"
        ssh1 "pgrep -a mariadbd" 2>&1 || true
        echo "--- datadirs"
        ssh3 "sudo -n ls -la ${NFS_ROOT}" 2>&1 || true
    } > "${dir}/preflight.log"

    if kubectl -n "${NS}" get pods --no-headers 2>/dev/null | grep -q .; then
        log "ERROR: Pods still exist in ${NS}; see ${dir}/preflight.log"
        exit 1
    fi
    if ssh3 "sudo -n ${FENCE_HELPER} status" >/dev/null 2>&1; then
        log "ERROR: the storage fence is active; see ${dir}/preflight.log"
        exit 1
    fi
    if ssh1 "pgrep mariadbd" >/dev/null 2>&1; then
        log "ERROR: a mariadbd process is running on Worker1; see ${dir}/preflight.log"
        exit 1
    fi
    ssh3 "sudo -n test -d ${BASELINE_DATADIR}" ||
        { log "ERROR: baseline datadir missing"; exit 1; }
}

wait_ready() {
    local node="$1" want="$2" timeout="$3" start s
    start="$(date +%s)"
    while true; do
        s="$(kubectl --request-timeout=10s get node "${node}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        [[ "${s}" == "${want}" ]] && return 0
        (( $(date +%s) - start >= timeout )) && return 1
        sleep 1
    done
}

# Pod with MariaDB and a writer sharing the server socket.
db_pod() {
    local name="$1" node="$2" datadir="$3" writer="$4" first_seq="$5" restart="${6:-Never}"
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    experiment: live-writer
spec:
  restartPolicy: ${restart}
  terminationGracePeriodSeconds: 30
  nodeSelector:
    kubernetes.io/hostname: ${node}
  tolerations:
    - key: node.kubernetes.io/unreachable
      operator: Exists
      effect: NoExecute
    - key: node.kubernetes.io/not-ready
      operator: Exists
      effect: NoExecute
  securityContext:
    runAsUser: 999
    runAsGroup: 999
  containers:
    - name: mariadb
      image: ${IMAGE}
      command: ["sh", "-ec", "exec mariadbd --datadir=/var/lib/mysql --socket=/run/fa/mariadb.sock --pid-file=/run/fa/mariadb.pid --skip-networking --innodb-flush-log-at-trx-commit=1"]
      volumeMounts:
        - {name: database, mountPath: /var/lib/mysql}
        - {name: run, mountPath: /run/fa}
YAML
    if [[ -n "${writer}" ]]; then
        cat <<YAML
    - name: writer
      image: ${IMAGE}
      command:
        - sh
        - -c
        - |
          S="--protocol=socket --socket=/run/fa/mariadb.sock -uroot -N -B"
          until mariadb \$S -e "SELECT 1" >/dev/null 2>&1; do sleep 1; done
          mariadb \$S -e "CREATE TABLE IF NOT EXISTS openmrs.fa_live_writer (seq BIGINT PRIMARY KEY, writer VARCHAR(32) NOT NULL, committed_at DATETIME(6) NOT NULL DEFAULT NOW(6)) ENGINE=InnoDB"
          echo "\$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ),0,ready"
          i=${first_seq}
          while true; do
            i=\$((i + 1))
            if mariadb \$S -e "INSERT INTO openmrs.fa_live_writer (seq, writer) VALUES (\$i, '${writer}')" 2>/dev/null; then
              echo "\$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ),\$i,ack"
            else
              echo "\$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ),\$i,error"
            fi
            sleep 0.2
          done
      volumeMounts:
        - {name: run, mountPath: /run/fa}
YAML
    fi
    cat <<YAML
  volumes:
    - name: database
      nfs: {server: ${WORKER3_IP}, path: ${datadir}}
    - name: run
      emptyDir: {}
YAML
}

sql_ready() {
    local pod="$1" timeout="$2" start
    start="$(date +%s)"
    until kubectl -n "${NS}" exec "${pod}" -c mariadb -- \
        mariadb --protocol=socket --socket=/run/fa/mariadb.sock -uroot -N -B -e "SELECT 1" >/dev/null 2>&1; do
        (( $(date +%s) - start >= timeout )) && return 1
        sleep 2
    done
}

clock_offset() {
    # Remote clock minus local clock, in seconds, with the RTT bound.
    local target="$1" t0 r t1
    t0="$(date +%s.%N)"
    r="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 "${target}" date +%s.%N)"
    t1="$(date +%s.%N)"
    python3 -c "t0,r,t1=${t0},${r},${t1}; print(f'{r-(t0+t1)/2:.6f},{(t1-t0)/2:.6f}')"
}

RUN_FAULT_ACTIVE="false"

run_cleanup() {
    set +e
    if [[ "${RUN_FAULT_ACTIVE}" == "true" ]]; then
        "${FAULT}" scenario-b clear
        RUN_FAULT_ACTIVE="false"
    fi
    # The fence and Pods are deliberately left as they are on an
    # error: removing a fence while the original writer may be alive
    # is unsafe. The run is marked ABORTED for manual inspection.
}

one_run() {
    local dir="$1" run_id="$2" arm="$3"
    local rdir="${dir}/runs/${run_id}"
    local datadir
    datadir="${NFS_ROOT}/lw-$(basename "${dir}")-${run_id}"

    [[ -f "${rdir}/COMPLETE" ]] && return 0
    [[ -d "${rdir}" ]] && mv "${rdir}" "${rdir}.attempt-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "${rdir}"
    trap run_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    log "RUN ${run_id} (${arm})"
    preflight "${rdir}"
    "${FAULT}" clear-all > "${rdir}/fault-preclear.log" 2>&1 || true
    wait_ready "${WORKER1_NODE}" True 300 && wait_ready "${WORKER2_NODE}" True 120

    # Fresh datadir copy on the storage server.
    ssh3 "sudo -n cp -a ${BASELINE_DATADIR} ${datadir} && sudo -n chown -R 999:999 ${datadir}"
    echo "${datadir}" > "${rdir}/datadir.txt"

    echo "host,offset_s,rtt_half_s" > "${rdir}/clock-offsets.csv"
    echo "worker1,$(clock_offset "${WORKER1_SSH}" || echo ,)" >> "${rdir}/clock-offsets.csv"
    echo "worker2,$(clock_offset "ubuntu@${WORKER2_IP}" || echo ,)" >> "${rdir}/clock-offsets.csv"

    db_pod lw-original "${WORKER1_NODE}" "${datadir}" original 0 | kubectl apply -f - >/dev/null
    sql_ready lw-original 180 || { echo "original not ready" > "${rdir}/ABORTED"; return 0; }
    sleep 20

    # --- Fault phase: no SSH to Worker1 from here until the fault ends.
    RUN_FAULT_ACTIVE="true"
    utc_now > "${rdir}/fault-time.txt"
    "${FAULT}" scenario-b apply > "${rdir}/fault-apply.log" 2>&1

    wait_ready "${WORKER1_NODE}" Unknown 180 ||
        { echo "no suspicion within 180 s" > "${rdir}/ABORTED"; return 0; }
    utc_now > "${rdir}/suspicion-time.txt"

    if [[ "${arm}" == "fenced" ]]; then
        ssh3 "sudo -n ${FENCE_HELPER} fence" > "${rdir}/fence.log" 2>&1
        ssh3 "sudo -n ${FENCE_HELPER} status" >> "${rdir}/fence.log" 2>&1 ||
            { echo "fence not verified" > "${rdir}/ABORTED"; return 0; }
        ssh3 "sudo -n iptables -L FA_WRITER_TEST -v -n -x" > "${rdir}/fence-counters-start.txt" 2>&1 || true
        utc_now > "${rdir}/fence-verified-time.txt"
    else
        sleep 10
    fi

    utc_now > "${rdir}/replacement-start-time.txt"
    db_pod lw-replacement "${WORKER2_NODE}" "${datadir}" replacement 1000000 OnFailure | kubectl apply -f - >/dev/null
    if sql_ready lw-replacement "${REPLACEMENT_WAIT_SECONDS}"; then
        utc_now > "${rdir}/replacement-sql-ready-time.txt"
    else
        echo "NOT_READY" > "${rdir}/replacement-sql-ready-time.txt"
    fi

    if [[ "${arm}" == "fenced" ]]; then
        sleep "${POST_FENCE_SECONDS}"
        ssh3 "sudo -n iptables -L FA_WRITER_TEST -v -n -x" > "${rdir}/fence-counters-end.txt" 2>&1 || true
    else
        local elapsed
        elapsed=$(( $(date +%s) - $(date -d "$(cat "${rdir}/fault-time.txt")" +%s) ))
        (( elapsed < UNFENCED_FAULT_SECONDS )) && sleep $(( UNFENCED_FAULT_SECONDS - elapsed ))
    fi

    kubectl -n "${NS}" logs lw-replacement -c mariadb > "${rdir}/replacement-mariadb.log" 2>&1 || true
    kubectl -n "${NS}" logs lw-replacement -c writer > "${rdir}/replacement-writer.csv" 2>&1 || true
    kubectl -n "${NS}" get pods -o wide > "${rdir}/pods-end-of-fault.txt" 2>&1 || true

    utc_now > "${rdir}/fault-clear-time.txt"
    "${FAULT}" scenario-b clear > "${rdir}/fault-clear.log" 2>&1
    RUN_FAULT_ACTIVE="false"
    # --- End of fault phase.

    wait_ready "${WORKER1_NODE}" True 300 || true
    kubectl -n "${NS}" logs lw-original -c writer > "${rdir}/original-writer.csv" 2>&1 || true
    kubectl -n "${NS}" logs lw-original -c mariadb > "${rdir}/original-mariadb.log" 2>&1 || true

    # Stop the replacement cleanly so its committed rows are flushed.
    kubectl -n "${NS}" delete pod lw-replacement --wait=true --timeout=120s >/dev/null 2>&1 || true

    if [[ "${arm}" == "fenced" ]]; then
        # Retire the original writer before the fence is removed. A process
        # blocked on fenced NFS cannot be stopped from Kubernetes, so the
        # worker is rebooted (as in the C+D reconciliation).
        utc_now > "${rdir}/retire-start-time.txt"
        ssh1 "sudo -n systemctl reboot" > /dev/null 2>&1 || true
        sleep 30
        local start; start="$(date +%s)"
        until ssh1 true 2>/dev/null; do
            (( $(date +%s) - start >= 900 )) && { echo "Worker1 did not return" > "${rdir}/ABORTED"; return 0; }
            sleep 10
        done
        wait_ready "${WORKER1_NODE}" True 600 || true
        ssh1 "pgrep -a mariadbd" > "${rdir}/worker1-mariadbd-after-reboot.txt" 2>&1 &&
            { echo "original mariadbd still present; fence kept" > "${rdir}/ABORTED"; return 0; }
        utc_now > "${rdir}/original-retired-time.txt"
        ssh3 "sudo -n ${FENCE_HELPER} unfence" > "${rdir}/unfence.log" 2>&1
        utc_now > "${rdir}/unfence-time.txt"
    fi

    kubectl -n "${NS}" delete pod lw-original --wait=true --timeout=180s >/dev/null 2>&1 ||
        kubectl -n "${NS}" delete pod lw-original --grace-period=0 --force >/dev/null 2>&1 || true
    if [[ "${arm}" == "unfenced" ]]; then
        sleep 5
        ssh1 "pgrep -a mariadbd" > "${rdir}/worker1-mariadbd-after-stop.txt" 2>&1 &&
            { echo "original mariadbd still present after stop" > "${rdir}/ABORTED"; return 0; }
    fi

    # Verifier: read every committed row from the datadir.
    db_pod lw-verify "${WORKER2_NODE}" "${datadir}" "" 0 OnFailure | kubectl apply -f - >/dev/null
    sql_ready lw-verify 300 || { echo "verifier not ready" > "${rdir}/ABORTED"; return 0; }
    kubectl -n "${NS}" exec lw-verify -c mariadb -- mariadb --protocol=socket --socket=/run/fa/mariadb.sock -uroot -N -B \
        -e "SELECT seq, writer, DATE_FORMAT(committed_at, '%Y-%m-%dT%H:%i:%s.%fZ') FROM openmrs.fa_live_writer ORDER BY seq" \
        | tr '\t' ',' > "${rdir}/committed-rows.csv"
    kubectl -n "${NS}" logs lw-verify -c mariadb > "${rdir}/verify-mariadb.log" 2>&1 || true
    kubectl -n "${NS}" delete pod lw-verify --wait=true --timeout=120s >/dev/null 2>&1 || true

    ssh3 "sudo -n rm -rf ${datadir}"
    utc_now > "${rdir}/COMPLETE"
    log "RUN ${run_id}: complete"
}

run_all() {
    local dir plan line _order run_id arm rc
    dir="$(campaign_dir)"
    # Strip carriage returns: a plan written with CRLF line endings would
    # otherwise leave "fenced\r" in the arm field and select the wrong branch.
    mapfile -t plan < <(tail -n +2 "${dir}/plan.csv" | tr -d '\r')
    for line in "${plan[@]}"; do
        IFS=',' read -r _order run_id arm <<< "${line}"
        [[ -f "${dir}/runs/${run_id}/COMPLETE" ]] && continue
        rc=0
        ( one_run "${dir}" "${run_id}" "${arm}" ) < /dev/null || rc=$?
        if [[ ! -f "${dir}/runs/${run_id}/COMPLETE" ]]; then
            [[ -f "${dir}/runs/${run_id}/ABORTED" ]] ||
                echo "exit code ${rc} at $(utc_now)" > "${dir}/runs/${run_id}/ABORTED"
            log "RUN ${run_id}: not completed; campaign stopped for inspection"
            log "Reason: $(cat "${dir}/runs/${run_id}/ABORTED")"
            exit 1
        fi
    done
    log "All runs complete"
}

status() {
    local dir
    dir="$(campaign_dir)"
    echo "Campaign: ${dir}"
    echo "Complete: $(find "${dir}/runs" -maxdepth 2 -name COMPLETE 2>/dev/null | wc -l)/$(($(wc -l < "${dir}/plan.csv") - 1))"
    find "${dir}/runs" -maxdepth 2 -name ABORTED -exec sh -c 'echo "$1: $(cat "$1")"' _ {} \; 2>/dev/null
}

case "${1:-}" in
    run) run_all ;;
    status) status ;;
    *) echo "Usage: $0 run|status" >&2; exit 1 ;;
esac
