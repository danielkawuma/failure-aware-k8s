#!/usr/bin/env bash
# ============================================================
# Midterm 2 supplementary campaign
#
#   ladder      Tuned-native baseline ladder (H1, H2) with
#               per-second EndpointSlice and in-cluster client
#               observation and controller resource sampling.
#   probe-grid  Probe error rates under workload-path loss (H4).
#   overhead    Controller overhead, 60-s windows (H5).
#   all         ladder, then probe-grid, then overhead.
#   status      Progress of the campaign.
#
# Usage:
#   SSH_KEY=~/.ssh/<key> scripts/ladder/campaign.sh all
#
# The campaign directory and its random seed are created on the
# first invocation and reused afterwards, so an interrupted
# campaign resumes where it stopped. Completed runs are never
# repeated or overwritten. Every attempt, completed or not,
# keeps its directory.
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../experiment-config.sh"

FAULT="${SCRIPT_DIR}/../fault.sh"
MANIFESTS="${REPO_ROOT}/workloads/ladder"
CAMPAIGN_ROOT="${REPO_ROOT}/experiments/evaluation/ladder"
CURRENT_LINK="${CAMPAIGN_ROOT}/CURRENT"

ARMS="${ARMS:-v0 t10 nx r2 fa1}"
RP_DURATIONS="${RP_DURATIONS:-120 600}"
UW_HOLD_SECONDS="${UW_HOLD_SECONDS:-480}"
REPS="${REPS:-5}"
LADDER_BASELINE_SECONDS="${LADDER_BASELINE_SECONDS:-10}"
LADDER_POST_CLEAR_SECONDS="${LADDER_POST_CLEAR_SECONDS:-60}"

PROBE_TRIALS="${PROBE_TRIALS:-100}"
OVERHEAD_WINDOWS="${OVERHEAD_WINDOWS:-30}"
OVERHEAD_WINDOW_SECONDS="${OVERHEAD_WINDOW_SECONDS:-60}"

CLIENT_POD="fa-ladder-client"

log() { printf '[LADDER %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
utc_now() { date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }
kc() { kubectl --request-timeout=15s "$@"; }

# ------------------------------------------------------------
# Campaign directory, seed, and plan
# ------------------------------------------------------------

campaign_dir() {
    if [[ -L "${CURRENT_LINK}" ]]; then
        readlink -f "${CURRENT_LINK}"
        return
    fi

    local id dir seed
    id="campaign-$(date -u +%Y%m%dT%H%M%SZ)"
    dir="${CAMPAIGN_ROOT}/${id}"
    seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"

    mkdir -p "${dir}"
    printf '%s\n' "${seed}" > "${dir}/seed.txt"
    ln -s "${id}" "${CURRENT_LINK}"

    python3 - "${dir}" "${seed}" "${ARMS}" "${RP_DURATIONS}" "${UW_HOLD_SECONDS}" "${REPS}" <<'PY'
import csv, random, sys
d, seed, arms, rp, uw, reps = sys.argv[1:]
rng = random.Random(int(seed))
cells = []
for arm in arms.split():
    for dur in rp.split():
        cells.append((arm, "rp", int(dur)))
    cells.append((arm, "uw", int(uw)))
rows = [(a, c, t, r) for (a, c, t) in cells for r in range(1, int(reps) + 1)]
rng.shuffle(rows)
with open(f"{d}/ladder-plan.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["order", "run_id", "arm", "condition", "fault_seconds", "rep"])
    for i, (a, c, t, r) in enumerate(rows, 1):
        w.writerow([i, f"r{i:03d}-{a}-{c}{t}", a, c, t, r])
PY

    {
        echo "campaign_id=${id}"
        echo "created_utc=$(utc_now)"
        echo "seed=${seed}"
        echo "git_commit=$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        echo "git_dirty=$(git -C "${REPO_ROOT}" status --porcelain | wc -l)"
        echo "arms=${ARMS}"
        echo "rp_durations=${RP_DURATIONS}"
        echo "uw_hold_seconds=${UW_HOLD_SECONDS}"
        echo "reps=${REPS}"
        echo "kubectl_server=$(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown)"
    } > "${dir}/campaign.env"

    log "Created ${dir} with seed ${seed}" >&2
    printf '%s\n' "${dir}"
}

# ------------------------------------------------------------
# Preflight
# ------------------------------------------------------------

preflight() {
    local dir="$1"

    log "Preflight"

    command -v python3 >/dev/null
    command -v kubectl >/dev/null
    command -v curl >/dev/null

    log "Building controller and harness"
    cargo build --quiet --manifest-path "${REPO_ROOT}/controller/Cargo.toml"
    cargo build --quiet --manifest-path "${REPO_ROOT}/harness/Cargo.toml"

    {
        echo "preflight_utc=$(utc_now)"
        echo "git_commit=$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        echo "controller_sha256=$(sha256sum "${CONTROLLER_BINARY}" | cut -d' ' -f1)"
        echo "harness_sha256=$(sha256sum "${HARNESS_BINARY}" | cut -d' ' -f1)"
        echo "rustc=$(rustc --version)"
    } >> "${dir}/preflight.log"

    "${FAULT}" clear-all || true

    for node in "${WORKER1_NODE}" "${WORKER2_NODE}"; do
        wait_node_ready "${node}" 180
    done

    ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 \
        "${WORKER1_SSH}" sudo -n true \
        || { log "ERROR: passwordless sudo on Worker1 is required"; exit 1; }

    kc get nodes -o wide >> "${dir}/preflight.log"
    kc get pods -A -o wide >> "${dir}/preflight.log"
    kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.failure-aware\.io/role}{"\n"}{end}' \
        >> "${dir}/preflight.log"

    ensure_client_pod
}

wait_node_ready() {
    local node="$1" timeout="${2:-120}" start status
    start="$(date +%s)"
    while true; do
        status="$(kc get node "${node}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        [[ "${status}" == "True" ]] && return 0
        (( $(date +%s) - start >= timeout )) && { log "Timeout waiting for ${node} Ready"; return 1; }
        sleep 2
    done
}

# An in-cluster client on Worker2 that requests the Service's
# ClusterIP once per second, so client reachability through the
# Service is recorded independently of the NodePort probes.
ensure_client_pod() {
    local phase svc_ip
    svc_ip="$(kc -n "${NAMESPACE}" get svc baseline-web -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    if [[ -z "${svc_ip}" ]]; then
        kubectl apply -f "${MANIFESTS}/nginx-nx.yaml" >/dev/null
        svc_ip="$(kc -n "${NAMESPACE}" get svc baseline-web -o jsonpath='{.spec.clusterIP}')"
    fi
    phase="$(kc -n "${NAMESPACE}" get pod "${CLIENT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == "Running" ]] && return 0

    kubectl -n "${NAMESPACE}" delete pod "${CLIENT_POD}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD}
  namespace: ${NAMESPACE}
  labels:
    app: fa-ladder-client
spec:
  nodeSelector:
    kubernetes.io/hostname: ${WORKER2_NODE}
  restartPolicy: Always
  containers:
    - name: client
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          while true; do
            ts=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if wget -q -T 2 -O /dev/null http://${svc_ip}/; then
              echo "\${ts},ok"
            else
              echo "\${ts},fail"
            fi
            sleep 1
          done
EOF
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${CLIENT_POD}" --timeout=180s
}

# ------------------------------------------------------------
# Workload reset
# ------------------------------------------------------------

workload_pods() {
    kc -n "${NAMESPACE}" get pods -l "${LABEL_SELECTOR}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"|"}{.spec.nodeName}{"|"}{.status.podIP}{"\n"}{end}' \
        2>/dev/null || true
}

# Prints "name|ip" of the single clean Running Pod on Worker1,
# and, for R2, requires exactly one more clean Pod elsewhere.
clean_start_state() {
    local arm="$1" on_w1=0 elsewhere=0 total=0 w1_pod=""
    while IFS='|' read -r name phase del node ip; do
        [[ -z "${name}" ]] && continue
        total=$((total + 1))
        [[ "${phase}" == "Running" && -z "${del}" && -n "${ip}" ]] || return 1
        if [[ "${node}" == "${WORKER1_NODE}" ]]; then
            on_w1=$((on_w1 + 1)); w1_pod="${name}|${ip}"
        else
            elsewhere=$((elsewhere + 1))
        fi
    done < <(workload_pods)

    if [[ "${arm}" == "r2" ]]; then
        (( on_w1 == 1 && elsewhere == 1 && total == 2 )) || return 1
    else
        (( on_w1 == 1 && total == 1 )) || return 1
    fi
    printf '%s\n' "${w1_pod}"
}

reset_workload() {
    local arm="$1" attempt start

    kubectl -n "${NAMESPACE}" delete deployment baseline-web --ignore-not-found --wait=true --timeout=120s >/dev/null || true
    kc -n "${NAMESPACE}" delete pdb baseline-web --ignore-not-found >/dev/null || true

    start="$(date +%s)"
    while [[ -n "$(workload_pods)" ]]; do
        (( $(date +%s) - start >= 180 )) && {
            log "Old workload Pods did not terminate; force-removing their API objects"
            kc -n "${NAMESPACE}" delete pod -l "${LABEL_SELECTOR}" --grace-period=0 --force >/dev/null 2>&1 || true
            sleep 5
            break
        }
        sleep 2
    done

    for attempt in 1 2 3; do
        kubectl apply -f "${MANIFESTS}/nginx-${arm}.yaml" >/dev/null
        kubectl -n "${NAMESPACE}" rollout status deployment/baseline-web --timeout=180s >/dev/null || true

        start="$(date +%s)"
        while (( $(date +%s) - start < 120 )); do
            if clean_start_state "${arm}" >/dev/null; then
                return 0
            fi
            sleep 2
        done

        log "Start state not clean (attempt ${attempt}); recreating Pods"
        kubectl -n "${NAMESPACE}" delete pod -l "${LABEL_SELECTOR}" --wait=true --timeout=120s >/dev/null || true
    done
    return 1
}

wait_http() {
    local url="$1" timeout="$2" start
    start="$(date +%s)"
    until curl --silent --max-time 2 --output /dev/null --fail "${url}"; do
        (( $(date +%s) - start >= timeout )) && return 1
        sleep 2
    done
}

# ------------------------------------------------------------
# Per-run observers
# ------------------------------------------------------------

endpoint_watch() {
    local out="$1"
    echo "timestamp_utc,endpoints" > "${out}"
    while true; do
        local ts payload
        ts="$(utc_now)"
        payload="$(kc -n "${NAMESPACE}" get endpointslices \
            -l "kubernetes.io/service-name=baseline-web" \
            -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{":"}{.nodeName}{":ready="}{.conditions.ready}{":serving="}{.conditions.serving}{":terminating="}{.conditions.terminating}{";"}{end}' \
            2>/dev/null || echo "API_ERROR")"
        printf '%s,"%s"\n' "${ts}" "${payload}" >> "${out}"
        sleep 1
    done
}

controller_sampler() {
    local pid="$1" out="$2" ticks_per_s
    ticks_per_s="$(getconf CLK_TCK)"
    echo "timestamp_utc,cpu_ticks,clk_tck,rss_kib" > "${out}"
    while kill -0 "${pid}" 2>/dev/null; do
        local ticks rss
        ticks="$(awk '{print $14 + $15}' "/proc/${pid}/stat" 2>/dev/null || echo "")"
        rss="$(awk '$1 == "VmRSS:" {print $2}' "/proc/${pid}/status" 2>/dev/null || echo "")"
        [[ -n "${ticks}" ]] && printf '%s,%s,%s,%s\n' "$(utc_now)" "${ticks}" "${ticks_per_s}" "${rss}" >> "${out}"
        sleep 1
    done
}

# Direct probe of the Worker1 NodePort from this host, the path the
# controller's verifier uses, once per second with a 3 s deadline.
worker1_probe() {
    local out="$1" url="http://${WORKER1_IP}:${NODEPORT}/"
    echo "timestamp_utc,success,http_code,latency_s" > "${out}"
    while true; do
        local ts result
        ts="$(utc_now)"
        result="$(curl --silent --output /dev/null --max-time 3 \
            --write-out '%{http_code},%{time_total}' "${url}" 2>/dev/null || true)"
        if [[ "${result%%,*}" =~ ^2 ]]; then
            echo "${ts},true,${result}" >> "${out}"
        else
            echo "${ts},false,${result:-000,0}" >> "${out}"
        fi
        sleep 1
    done
}

# ------------------------------------------------------------
# One ladder run
# ------------------------------------------------------------

RUN_FAULT_ACTIVE="false"
RUN_FAULT_SCENARIO=""
RUN_HARNESS_PID=""
RUN_PIDS=()

# Clears an active fault and stops this run's observers. Runs on
# every exit path of a run, including errors and interruption.
run_cleanup() {
    set +e
    if [[ "${RUN_FAULT_ACTIVE}" == "true" ]]; then
        "${FAULT}" "${RUN_FAULT_SCENARIO}" clear
        RUN_FAULT_ACTIVE="false"
    fi
    # The harness saves its observations on SIGINT; background shell
    # loops ignore SIGINT, so they are stopped with SIGTERM.
    [[ -n "${RUN_HARNESS_PID}" ]] && kill -INT "${RUN_HARNESS_PID}" 2>/dev/null
    for p in "${RUN_PIDS[@]}"; do
        kill -TERM "${p}" 2>/dev/null
    done
    if [[ -n "${RUN_HARNESS_PID}" ]]; then
        local waited=0
        while kill -0 "${RUN_HARNESS_PID}" 2>/dev/null && (( waited < 30 )); do
            sleep 1
            waited=$((waited + 1))
        done
        kill -TERM "${RUN_HARNESS_PID}" 2>/dev/null
        wait "${RUN_HARNESS_PID}" 2>/dev/null
    fi
    for p in "${RUN_PIDS[@]}"; do
        wait "${p}" 2>/dev/null
    done
    RUN_HARNESS_PID=""
    RUN_PIDS=()
}

ladder_run() {
    local dir="$1" run_id="$2" arm="$3" condition="$4" fault_seconds="$5"
    local rdir="${dir}/runs/${run_id}"

    if [[ -f "${rdir}/COMPLETE" ]]; then
        return 0
    fi

    # Never overwrite an earlier attempt: keep it beside the new one.
    if [[ -d "${rdir}" ]]; then
        mv "${rdir}" "${rdir}.attempt-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "${rdir}"

    log "RUN ${run_id}: arm=${arm} condition=${condition} fault=${fault_seconds}s"

    trap run_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    "${FAULT}" clear-all > "${rdir}/fault-preclear.log" 2>&1 || true
    wait_node_ready "${WORKER1_NODE}" 180 && wait_node_ready "${WORKER2_NODE}" 180 \
        || { echo "nodes not ready $(utc_now)" > "${rdir}/ABORTED"; return 0; }

    ensure_client_pod >/dev/null

    if ! reset_workload "${arm}"; then
        echo "clean start state not reached $(utc_now)" > "${rdir}/ABORTED"
        workload_pods > "${rdir}/pods-at-abort.txt"
        return 0
    fi

    local original original_pod original_ip
    original="$(clean_start_state "${arm}")"
    original_pod="${original%%|*}"
    original_ip="${original##*|}"

    if ! wait_http "http://${WORKER1_IP}:${NODEPORT}" 60; then
        echo "workload not reachable before fault $(utc_now)" > "${rdir}/ABORTED"
        return 0
    fi

    kc -n "${NAMESPACE}" get pod "${original_pod}" -o json > "${rdir}/original-pod.json"
    kc -n "${NAMESPACE}" get pods -o wide > "${rdir}/pods-before.txt"
    kc get nodes -o wide > "${rdir}/nodes-before.txt"
    local client_ip
    client_ip="$(kc -n "${NAMESPACE}" get svc baseline-web -o jsonpath='{.spec.clusterIP}')"

    local harness_config
    if [[ "${condition}" == "rp" ]]; then
        harness_config="${SCENARIO_B_CONFIG}"
        RUN_FAULT_SCENARIO="scenario-b"
    else
        harness_config="${SCENARIO_C_CONFIG}"
        RUN_FAULT_SCENARIO="scenario-c"
    fi

    # The harness measures one fixed client path: the Service through the
    # Worker2 NodePort, i.e. a client entering the cluster on a node that
    # is not partitioned. Without measurement_url it would follow the Pod.
    python3 - "${harness_config}" "${rdir}/harness-config.json" "http://${WORKER2_IP}:${NODEPORT}" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["measurement_url"] = sys.argv[3]
json.dump(c, open(sys.argv[2], "w"), indent=2)
PY

    HARNESS_CONFIG="${rdir}/harness-config.json" "${HARNESS_BINARY}" > "${rdir}/harness.log" 2>&1 &
    RUN_HARNESS_PID="$!"

    worker1_probe "${rdir}/worker1-nodeport-observations.csv" &
    RUN_PIDS+=("$!")

    endpoint_watch "${rdir}/endpointslice-observations.csv" &
    RUN_PIDS+=("$!")

    if [[ "${arm}" == "fa1" ]]; then
        ( cd "${REPO_ROOT}" && exec "${CONTROLLER_BINARY}" ) > "${rdir}/controller.log" 2>&1 &
        local cpid=$!
        RUN_PIDS+=("${cpid}")
        controller_sampler "${cpid}" "${rdir}/controller-resource-samples.csv" &
        RUN_PIDS+=("$!")
    else
        echo "Native arm ${arm}: Failure-Aware controller not started." > "${rdir}/controller.log"
    fi

    sleep "${LADDER_BASELINE_SECONDS}"

    local run_start
    run_start="$(utc_now)"

    python3 - "${rdir}/experiment-metadata.json" <<PY
import json, sys
json.dump({
  "campaign": "$(basename "${dir}")",
  "run_id": "${run_id}",
  "arm": "${arm}",
  "condition": "${condition}",
  "fault_seconds": ${fault_seconds},
  "run_start_utc": "${run_start}",
  "original_pod": "${original_pod}",
  "original_pod_ip": "${original_ip}",
  "original_node": "${WORKER1_NODE}",
  "service_cluster_ip": "${client_ip}",
  "nodeport": ${NODEPORT},
  "git_commit": "$(git -C "${REPO_ROOT}" rev-parse HEAD)",
  "seed": "$(cat "${dir}/seed.txt")"
}, open(sys.argv[1], "w"), indent=2)
PY

    # Marked active before applying, so a partial apply is still cleared.
    RUN_FAULT_ACTIVE="true"
    utc_now > "${rdir}/fault-time.txt"
    if [[ "${condition}" == "rp" ]]; then
        "${FAULT}" scenario-b apply > "${rdir}/fault-apply.log" 2>&1
    else
        "${FAULT}" scenario-c apply "${original_ip}" > "${rdir}/fault-apply.log" 2>&1
    fi

    sleep "${fault_seconds}"

    utc_now > "${rdir}/fault-clear-time.txt"
    "${FAULT}" "${RUN_FAULT_SCENARIO}" clear > "${rdir}/fault-clear.log" 2>&1
    RUN_FAULT_ACTIVE="false"

    sleep "${LADDER_POST_CLEAR_SECONDS}"

    kc -n "${NAMESPACE}" get pods -o wide > "${rdir}/pods-after.txt" || true
    kc get nodes -o wide > "${rdir}/nodes-after.txt" || true
    kc -n "${NAMESPACE}" get events --sort-by=.lastTimestamp > "${rdir}/events-after.txt" || true
    kc -n "${NAMESPACE}" logs "${CLIENT_POD}" --since-time="${run_start}" > "${rdir}/client-clusterip-observations.csv" 2>/dev/null || true

    run_cleanup

    local harness_out
    harness_out="$(sed -n 's/^Output directory: //p' "${rdir}/harness.log" | head -n 1)"
    if [[ -n "${harness_out}" && -d "${harness_out}" ]]; then
        cp -a "${harness_out}/." "${rdir}/"
        echo "${harness_out}" > "${rdir}/harness-source-directory.txt"
    fi

    utc_now > "${rdir}/COMPLETE"
    log "RUN ${run_id}: complete"
}

ladder() {
    local dir
    dir="$(campaign_dir)"
    preflight "${dir}"

    local total done_count
    total="$(($(wc -l < "${dir}/ladder-plan.csv") - 1))"

    local plan=() line order run_id arm condition fault_seconds _rep rc
    mapfile -t plan < <(tail -n +2 "${dir}/ladder-plan.csv")

    for line in "${plan[@]}"; do
        IFS=',' read -r order run_id arm condition fault_seconds _rep <<< "${line}"
        [[ -f "${dir}/runs/${run_id}/COMPLETE" ]] && continue

        # Each run executes in its own subshell, so a failure in one run
        # clears its fault and stops its observers without ending the
        # campaign. The attempt directory is kept and marked ABORTED.
        rc=0
        ( ladder_run "${dir}" "${run_id}" "${arm}" "${condition}" "${fault_seconds}" ) < /dev/null || rc=$?

        if [[ ! -f "${dir}/runs/${run_id}/COMPLETE" ]]; then
            [[ -f "${dir}/runs/${run_id}/ABORTED" ]] ||
                echo "exit code ${rc} at $(utc_now)" > "${dir}/runs/${run_id}/ABORTED"
            log "RUN ${run_id}: not completed (exit ${rc})"
            (( rc == 130 || rc == 143 )) && exit "${rc}"
        fi

        done_count="$(find "${dir}/runs" -maxdepth 2 -name COMPLETE | wc -l)"
        log "Progress: ${done_count}/${total} complete"
    done

    "${FAULT}" clear-all || true
    kc -n "${NAMESPACE}" delete deployment baseline-web --ignore-not-found >/dev/null || true
    kc -n "${NAMESPACE}" delete pdb baseline-web --ignore-not-found >/dev/null || true
    kc apply -f "${MANIFESTS}/nginx-fa1.yaml" >/dev/null
}

# ------------------------------------------------------------
# Probe-error grid
# ------------------------------------------------------------

probe_grid() {
    local dir
    dir="$(campaign_dir)"
    mkdir -p "${dir}/probe-grid"

    if [[ -f "${dir}/probe-grid/COMPLETE" ]]; then
        log "Probe grid already complete"
        return 0
    fi

    "${FAULT}" clear-all || true
    wait_node_ready "${WORKER1_NODE}" 180
    reset_workload nx || { log "ERROR: probe-grid workload not ready"; return 1; }
    wait_http "http://${WORKER1_IP}:${NODEPORT}" 60

    python3 "${SCRIPT_DIR}/probe_grid.py" \
        --output "${dir}/probe-grid" \
        --seed "$(cat "${dir}/seed.txt")" \
        --trials "${PROBE_TRIALS}" \
        --url "http://${WORKER1_IP}:${NODEPORT}/" \
        --nodeport "${NODEPORT}" \
        --ssh-key "${SSH_KEY}" \
        --ssh-target "${WORKER1_SSH}"

    utc_now > "${dir}/probe-grid/COMPLETE"
}

# ------------------------------------------------------------
# Controller overhead (60-s windows, controller version as built)
# ------------------------------------------------------------

overhead() {
    local dir out iface
    dir="$(campaign_dir)"
    out="${dir}/overhead"
    mkdir -p "${out}"

    if [[ -f "${out}/COMPLETE" ]]; then
        log "Overhead already complete"
        return 0
    fi

    "${FAULT}" clear-all || true
    reset_workload fa1 || true

    iface="${NETWORK_INTERFACE:-$(ip route show default | awk 'NR == 1 {print $5}')}"
    local csv="${out}/controller-overhead-windows.csv"
    local pattern="${CONTROLLER_BINARY}"

    sha256sum "${CONTROLLER_BINARY}" > "${out}/controller-binary.sha256"
    git -C "${REPO_ROOT}" rev-parse HEAD > "${out}/git-commit.txt"

    local i mode cpid
    for ((i = 1; i <= OVERHEAD_WINDOWS; i++)); do
        # Alternate the order within each pair so neither mode
        # always follows the other.
        local order="native failure-aware"
        (( i % 2 == 0 )) && order="failure-aware native"

        for mode in ${order}; do
            local wid
            wid="$(printf 'w%03d-%s' "${i}" "${mode}")"
            grep -q ",${wid}," "${csv}" 2>/dev/null && continue

            cpid=""
            if [[ "${mode}" == "failure-aware" ]]; then
                ( cd "${REPO_ROOT}" && exec "${CONTROLLER_BINARY}" ) >> "${out}/controller.log" 2>&1 &
                cpid=$!
                sleep 5
            fi

            RUN_ID="${wid}" \
            MODE="${mode}" \
            PROCESS_PATTERN="${pattern}" \
            NETWORK_INTERFACE="${iface}" \
            OUTPUT="${csv}" \
            APPEND="true" \
            PHASE="steady-state" \
            DURATION_SECONDS="${OVERHEAD_WINDOW_SECONDS}" \
            INTERVAL_SECONDS="1" \
            EXPECT_PROCESS="$([[ "${mode}" == "failure-aware" ]] && echo required || echo absent)" \
            "${SCRIPT_DIR}/../overhead/collect-overhead.sh"

            if [[ -n "${cpid}" ]]; then
                kill "${cpid}" 2>/dev/null || true
                wait "${cpid}" 2>/dev/null || true
                sleep 2
            fi
        done
        log "Overhead window pair ${i}/${OVERHEAD_WINDOWS} done"
    done

    utc_now > "${out}/COMPLETE"
}

status() {
    local dir
    dir="$(campaign_dir)"
    echo "Campaign: ${dir}"
    echo "Seed:     $(cat "${dir}/seed.txt")"
    echo "Ladder:   $(find "${dir}/runs" -maxdepth 2 -name COMPLETE 2>/dev/null | wc -l)/$(($(wc -l < "${dir}/ladder-plan.csv") - 1)) complete, $(find "${dir}/runs" -maxdepth 2 -name ABORTED 2>/dev/null | wc -l) aborted"
    echo "Probe:    $([[ -f "${dir}/probe-grid/COMPLETE" ]] && echo complete || echo pending)"
    echo "Overhead: $([[ -f "${dir}/overhead/COMPLETE" ]] && echo complete || echo pending)"
}

case "${1:-}" in
    ladder)     ladder ;;
    probe-grid) probe_grid ;;
    overhead)   overhead ;;
    all)        ladder; probe_grid; overhead; status ;;
    status)     status ;;
    *)
        echo "Usage: $0 ladder|probe-grid|overhead|all|status" >&2
        exit 1
        ;;
esac
