#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCENARIO="${1:-}"
MODE="${2:-}"
ID="${3:-}"
PROFILE="${4:-mild}"

case "$SCENARIO" in
    scenario-c|scenario-e) ;;
    *)
        echo "Usage: $0 scenario-c|scenario-e V0|T5|T10|T30|FA1 RUN_ID [profile]" >&2
        exit 2
        ;;
esac

case "$MODE" in
    V0|T5|T10|T30|FA1) ;;
    *)
        echo "Invalid mode: $MODE" >&2
        exit 2
        ;;
esac

[[ "$ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2

case "$PROFILE" in
    mild|moderate|severe) ;;
    *)
        echo "Invalid Scenario E profile" >&2
        exit 2
        ;;
esac

NAMESPACE="${OPENMRS_NAMESPACE:-openmrs37}"
DEPLOYMENT="openmrs-backend"
SELECTOR="app=openmrs-backend"

RUN="$ROOT/experiments/evaluation/openmrs/$SCENARIO/$MODE/run-$ID"

if [[ "$SCENARIO" == scenario-e ]]; then
    RUN="$ROOT/experiments/evaluation/openmrs/$SCENARIO/$PROFILE/$MODE/run-$ID"
fi

[[ ! -e "$RUN" ]] || {
    echo "Existing result: $RUN" >&2
    exit 1
}

mkdir -p "$RUN"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"

BASELINE_SECONDS="${BASELINE_SECONDS:-30}"
FAULT_SECONDS="${FAULT_SECONDS:-600}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-1200}"
POST_FAULT_SECONDS="${POST_FAULT_SECONDS:-30}"

C_MAX_FAULT_SECONDS="${C_MAX_FAULT_SECONDS:-900}"
C_RECOVERY_STABILITY_SECONDS="${C_RECOVERY_STABILITY_SECONDS:-30}"
C_POST_FAULT_SECONDS="${C_POST_FAULT_SECONDS:-60}"

if [[ "$SCENARIO" == scenario-e ]]; then
    FAULT_SECONDS="${E_FAULT_SECONDS:-120}"
fi

E_POST_CLEAR_TIMEOUT_SECONDS="${E_POST_CLEAR_TIMEOUT_SECONDS:-900}"
E_CLINICAL_STABILITY_SECONDS="${E_CLINICAL_STABILITY_SECONDS:-30}"
E_MAX_CONSECUTIVE_POD_OBSERVATION_FAILURES="${E_MAX_CONSECUTIVE_POD_OBSERVATION_FAILURES:-3}"

for value in \
    "$BASELINE_SECONDS" \
    "$FAULT_SECONDS" \
    "$RECOVERY_TIMEOUT_SECONDS" \
    "$POST_FAULT_SECONDS" \
    "$C_MAX_FAULT_SECONDS" \
    "$C_RECOVERY_STABILITY_SECONDS" \
    "$C_POST_FAULT_SECONDS" \
    "$E_POST_CLEAR_TIMEOUT_SECONDS" \
    "$E_CLINICAL_STABILITY_SECONDS" \
    "$E_MAX_CONSECUTIVE_POD_OBSERVATION_FAILURES"
do
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "Invalid numeric timing parameter: $value" >&2
        exit 2
    }
done

(( RECOVERY_TIMEOUT_SECONDS > 0 )) || exit 2
(( C_MAX_FAULT_SECONDS > 0 )) || exit 2
(( C_RECOVERY_STABILITY_SECONDS > 0 )) || exit 2
(( E_POST_CLEAR_TIMEOUT_SECONDS > E_CLINICAL_STABILITY_SECONDS )) || exit 2
(( E_CLINICAL_STABILITY_SECONDS > 0 )) || exit 2
(( E_MAX_CONSECUTIVE_POD_OBSERVATION_FAILURES > 0 )) || exit 2

if [[ "$SCENARIO" == scenario-c ]]; then
    (( RECOVERY_TIMEOUT_SECONDS >
       C_MAX_FAULT_SECONDS + C_POST_FAULT_SECONDS )) || {
        echo "Recovery timeout must exceed maximum fault hold plus post-fault observation" >&2
        exit 2
    }
fi

HARNESS="$ROOT/harness/target/debug/failure-aware-harness"
CONTROLLER="$ROOT/controller/target/debug/failure-aware-controller"

CONFIG="$ROOT/controller/config/openmrs-backend.json"
HARNESS_CONFIG="$ROOT/harness/config/openmrs-$SCENARIO.json"

FAULT_C="$ROOT/scripts/openmrs-c-fault.sh"
FAULT_E="$ROOT/scripts/fault.sh"

# Use an unaffected worker for clinical verification.
# This must be independently verified as reachable before the campaign.
TARGET_URL="${OPENMRS_CLINICAL_URL:-http://102.34.160.103:30366/openmrs/health/started}"

HPID=''
CPID=''

FAULT_ATTEMPTED=false
FAULT_CLEARED=false
COMPLETE=false

RESTORED=false
REPLACEMENT=''
RECOVERY_STABLE_START=-1
RECOVERY_STABILITY_CONFIRMED=false
FAULT_CLEAR_REASON=''
POST_CLEAR_START=-1
RECOVERY_OUTCOME=''
E_STABLE_START=-1
E_HAD_CLINICAL_FAILURE=false
E_FIRST_POST_CLEAR_HEALTH=false
E_CLINICAL_STABLE=false

utc() {
    date -u +'%Y-%m-%dT%H:%M:%S.%NZ'
}

log() {
    printf '[%s] %s\n' "$(utc)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

node() {
    kubectl --request-timeout=15s \
        get pod "$1" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.nodeName}'
}

ready_pod() {
    kubectl --request-timeout=15s \
        get pods -n "$NAMESPACE" \
        -l "$SELECTOR" -o json |
    python3 -c '
import json
import sys

items = json.load(sys.stdin)["items"]

ready = [
    p for p in items
    if p["status"].get("phase") == "Running"
    and not p["metadata"].get("deletionTimestamp")
    and any(
        c.get("type") == "Ready"
        and c.get("status") == "True"
        for c in p["status"].get("conditions", [])
    )
]

if len(ready) != 1:
    sys.exit(1)

print(ready[0]["metadata"]["name"])
'
}

clinical() {
    curl -fsS \
        --connect-timeout 2 \
        --max-time 8 \
        "$TARGET_URL" >/dev/null
}

clear_fault() {
    if [[ "$SCENARIO" == scenario-c ]]; then
        "$FAULT_C" clear
    else
        "$FAULT_E" scenario-e clear
    fi
}

apply_fault() {
    if [[ "$SCENARIO" == scenario-c ]]; then
        "$FAULT_C" apply "$ORIGINAL_IP"
    else
        "$FAULT_E" scenario-e apply "$PROFILE"
    fi
}

verify_fault_clear() {
    if [[ "$SCENARIO" == scenario-c ]]; then
        "$FAULT_C" absent
    else
        "$FAULT_E" scenario-e show | grep -q 'none'
    fi
}

snapshot() {
    kubectl --request-timeout=15s \
        get pods -n "$NAMESPACE" -o wide \
        > "$RUN/$1-pods.txt" 2>&1 || true

    kubectl --request-timeout=15s \
        get events -n "$NAMESPACE" \
        --sort-by=.metadata.creationTimestamp \
        > "$RUN/$1-events.txt" 2>&1 || true

    kubectl --request-timeout=15s \
        get nodes -o wide \
        > "$RUN/$1-nodes.txt" 2>&1 || true
}

release_fault() {
    local reason="$1"

    [[ "$FAULT_CLEARED" != true ]] || return 0

    log "Clearing fault: $reason"

    clear_fault > "$RUN/fault-clear.log" 2>&1 ||
        fail "Fault clearing failed"

    verify_fault_clear ||
        fail "Fault clearance could not be verified"

    FAULT_CLEARED=true
    FAULT_CLEAR_REASON="$reason"

    utc > "$RUN/fault-clear-time.txt"
    printf '%s\n' "$reason" > "$RUN/fault-clear-reason.txt"

    log "Fault cleared and verified: $reason"
}

cleanup() {
    local rc=$?

    trap - EXIT INT TERM
    set +e

    if [[ "$FAULT_ATTEMPTED" == true &&
          "$FAULT_CLEARED" != true ]]; then

        log "Emergency fault cleanup"

        if clear_fault > "$RUN/emergency-clear.log" 2>&1 &&
           verify_fault_clear; then
            FAULT_CLEARED=true
            utc > "$RUN/fault-clear-time.txt"
            printf '%s\n' "EMERGENCY_CLEANUP" \
                > "$RUN/fault-clear-reason.txt"
        fi
    fi

    if [[ -n "$HPID" ]]; then
        kill -INT "$HPID" 2>/dev/null
        wait "$HPID" 2>/dev/null
    fi

    if [[ -n "$CPID" ]]; then
        kill "$CPID" 2>/dev/null
        wait "$CPID" 2>/dev/null
    fi

    snapshot final

    if [[ "$COMPLETE" == true &&
          "$FAULT_CLEARED" == true ]] &&
       verify_fault_clear; then

        touch "$RUN/COMPLETE"
        rm -f "$RUN/INCOMPLETE"
    else
        touch "$RUN/INCOMPLETE"
        rc=1
    fi

    log "Results: $RUN (exit=$rc)"
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "${OPENMRS_ENABLE_FAULTS:-false}" == true ]] ||
    fail "Set OPENMRS_ENABLE_FAULTS=true"

[[ -x "$HARNESS" &&
   -f "$HARNESS_CONFIG" &&
   -f "$SSH_KEY" ]] ||
    fail "Harness, configuration or SSH key missing"

if [[ "$MODE" == FA1 ]]; then
    [[ -x "$CONTROLLER" && -f "$CONFIG" ]] ||
        fail "Controller or configuration missing"
fi

verify_fault_clear ||
    fail "Existing fault or unverifiable fault state"

ORIGINAL="$(ready_pod)" ||
    fail "Exactly one Ready backend required"

ORIGINAL_NODE="$(node "$ORIGINAL")"

[[ "$ORIGINAL_NODE" == k3s-worker1 ]] ||
    fail "Expected original backend on Worker1; got $ORIGINAL_NODE"

ORIGINAL_IP="$(
    kubectl --request-timeout=15s \
        get pod "$ORIGINAL" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.podIP}'
)"

[[ -n "$ORIGINAL_IP" ]] ||
    fail "Missing original Pod IP"

clinical ||
    fail "Clinical service unhealthy before fault"

EXPECTED=300

case "$MODE" in
    T5) EXPECTED=5 ;;
    T10) EXPECTED=10 ;;
    T30) EXPECTED=30 ;;
esac

if [[ "$MODE" != FA1 ]]; then

    ACTUAL="$(
        kubectl --request-timeout=15s \
            get pod "$ORIGINAL" \
            -n "$NAMESPACE" -o json |
        python3 -c '
import json
import sys

pod = json.load(sys.stdin)
ts = pod["spec"].get("tolerations", [])

keys = {
    "node.kubernetes.io/unreachable",
    "node.kubernetes.io/not-ready"
}

vals = [
    t.get("tolerationSeconds")
    for t in ts
    if t.get("key") in keys
    and t.get("effect") == "NoExecute"
]

print(
    vals[0]
    if len(vals) == 2 and vals[0] == vals[1]
    else "INVALID"
)
'
    )"

    [[ "$ACTUAL" == "$EXPECTED" ]] ||
        fail "Expected $EXPECTED second tolerations, found $ACTUAL"
else
    kubectl --request-timeout=15s \
        get pod "$ORIGINAL" \
        -n "$NAMESPACE" -o json |
    python3 -c '
import json
import sys

pod = json.load(sys.stdin)
ts = pod["spec"].get("tolerations", [])

for key in (
    "node.kubernetes.io/not-ready",
    "node.kubernetes.io/unreachable"
):
    matches = [
        t for t in ts
        if t.get("key") == key
        and t.get("effect") == "NoExecute"
        and t.get("operator") == "Exists"
    ]

    if len(matches) != 1:
        sys.exit(1)

    if matches[0].get("tolerationSeconds") is not None:
        sys.exit(1)
' || fail "FA1 indefinite tolerations not verified"
fi

snapshot before

utc > "$RUN/preflight-time.txt"

cat > "$RUN/metadata.env" <<EOF
scenario=$SCENARIO
mode=$MODE
profile=$PROFILE
original_pod=$ORIGINAL
original_node=$ORIGINAL_NODE
original_ip=$ORIGINAL_IP
clinical_url=$TARGET_URL
fault_protocol=$(
    if [[ "$SCENARIO" == scenario-c ]]; then
        echo recovery-triggered-v3
    else
        echo fixed-duration
    fi
)
configured_fault_seconds=$FAULT_SECONDS
c_max_fault_seconds=$C_MAX_FAULT_SECONDS
c_recovery_stability_seconds=$C_RECOVERY_STABILITY_SECONDS
c_post_fault_seconds=$C_POST_FAULT_SECONDS
recovery_timeout_seconds=$RECOVERY_TIMEOUT_SECONDS
e_post_clear_timeout_seconds=$E_POST_CLEAR_TIMEOUT_SECONDS
e_clinical_stability_seconds=$E_CLINICAL_STABILITY_SECONDS
e_max_consecutive_pod_observation_failures=$E_MAX_CONSECUTIVE_POD_OBSERVATION_FAILURES
EOF

HARNESS_CONFIG="$HARNESS_CONFIG" \
    "$HARNESS" > "$RUN/harness.log" 2>&1 &

HPID=$!

if [[ "$MODE" == FA1 ]]; then
    (
        cd "$ROOT"
        FAILURE_AWARE_CONTROLLER_CONFIG="$CONFIG" \
            "$CONTROLLER"
    ) > "$RUN/controller.log" 2>&1 &

    CPID=$!
fi

sleep "$BASELINE_SECONDS"

kill -0 "$HPID" 2>/dev/null ||
    fail "Harness exited during baseline"

if [[ -n "$CPID" ]]; then
    kill -0 "$CPID" 2>/dev/null ||
        fail "Controller exited during baseline"
fi

utc > "$RUN/fault-time.txt"

FAULT_ATTEMPTED=true

apply_fault > "$RUN/fault-apply.log" 2>&1 ||
    fail "Fault injection failed"

log "Fault active: $SCENARIO $MODE"

START=$SECONDS
FAULT_END=$((START + FAULT_SECONDS))
C_FAULT_LIMIT=$((START + C_MAX_FAULT_SECONDS))
DEADLINE=$((START + RECOVERY_TIMEOUT_SECONDS))
if [[ "$SCENARIO" == scenario-e ]]; then
    DEADLINE=$((FAULT_END + E_POST_CLEAR_TIMEOUT_SECONDS))
fi

printf 'utc,pod,node,phase,ready,clinical_ok\n' \
    > "$RUN/recovery-observations.csv"

printf 'utc,replacement,ready,clinical_ok,stable_seconds,fault_cleared\n' \
    > "$RUN/recovery-stability.csv"

FIRST_RECOVERY_RECORDED=false
FIRST_READY_RECORDED=false
REPLACEMENT_CREATED_RECORDED=false
E_CONSECUTIVE_POD_OBSERVATION_FAILURES=0
E_TOTAL_POD_OBSERVATION_FAILURES=0
printf 'utc,consecutive_failures,reason\n' > "$RUN/pod-observation-gaps.csv"
printf 'utc,clinical_ok,pod_observation_ok\n' > "$RUN/e-clinical-observations.csv"

while (( SECONDS < DEADLINE )); do

    kill -0 "$HPID" 2>/dev/null ||
        fail "Harness exited during experiment"

    if [[ -n "$CPID" ]]; then
        kill -0 "$CPID" 2>/dev/null ||
            fail "Controller exited during experiment"
    fi

    if [[ "$SCENARIO" == scenario-e &&
          "$FAULT_CLEARED" != true ]] &&
       (( SECONDS >= FAULT_END )); then

        release_fault "FIXED_DURATION"
    fi

    if [[ "$SCENARIO" == scenario-c &&
          "$FAULT_CLEARED" != true ]] &&
       (( SECONDS >= C_FAULT_LIMIT )); then

        release_fault "MAX_FAULT_DURATION"
    fi

    # Scenario E measures clinical health independently of Kubernetes
    # observation. A failed API lookup must not be counted as an HTTP failure.
    if [[ "$SCENARIO" == scenario-e ]]; then
        OK=false
        if clinical; then OK=true; fi
    fi

    PODS_ERROR=''
    PODS_RC=0
    PODS="$(
        kubectl --request-timeout=15s \
            get pods -n "$NAMESPACE" \
            -l "$SELECTOR" -o json 2> "$RUN/last-pod-observation-error.txt"
    )" || PODS_RC=$?

    if (( PODS_RC != 0 )); then
        PODS_ERROR="$(cat "$RUN/last-pod-observation-error.txt")"
        [[ -n "$PODS_ERROR" ]] || PODS_ERROR="kubectl exited $PODS_RC"
        if [[ "$SCENARIO" != scenario-e ]]; then
            fail "Cannot observe Pods: $PODS_ERROR"
        fi
        printf '%s,%s,%s\n' "$(utc)" "$OK" false >> "$RUN/e-clinical-observations.csv"
        if [[ "$OK" != true ]]; then E_HAD_CLINICAL_FAILURE=true; fi
        E_CONSECUTIVE_POD_OBSERVATION_FAILURES=$((E_CONSECUTIVE_POD_OBSERVATION_FAILURES + 1))
        E_TOTAL_POD_OBSERVATION_FAILURES=$((E_TOTAL_POD_OBSERVATION_FAILURES + 1))
        printf '%s,%s,%s\n' "$(utc)" "$E_CONSECUTIVE_POD_OBSERVATION_FAILURES" "$(printf '%s' "$PODS_ERROR" | tr '\n,' '  ')" >> "$RUN/pod-observation-gaps.csv"
        log "Scenario E Pod observation gap $E_CONSECUTIVE_POD_OBSERVATION_FAILURES: $PODS_ERROR"
        if (( E_CONSECUTIVE_POD_OBSERVATION_FAILURES > E_MAX_CONSECUTIVE_POD_OBSERVATION_FAILURES )); then
            fail "Scenario E exceeded consecutive Pod observation failure limit"
        fi
        # Clinical result above is retained even when Pod metadata is unavailable.
        # Do not infer placement or replacement from stale data.
        # Stability can only be confirmed with a successful observation.
        E_STABLE_START=-1
        sleep 3
        continue
    fi
    if [[ "$SCENARIO" == scenario-e ]]; then
        E_CONSECUTIVE_POD_OBSERVATION_FAILURES=0
    fi

    mapfile -t STATES < <(
        printf '%s' "$PODS" |
        python3 -c '
import json
import sys

data = json.load(sys.stdin)

for p in data["items"]:
    name = p["metadata"]["name"]
    node = p["spec"].get("nodeName", "")
    phase = p["status"].get("phase", "")

    ready = any(
        c.get("type") == "Ready"
        and c.get("status") == "True"
        for c in p["status"].get("conditions", [])
    )

    deleting = bool(
        p["metadata"].get("deletionTimestamp")
    )

    created = p["metadata"].get("creationTimestamp", "")

    print("|".join([
        name,
        node,
        phase,
        str(ready).lower(),
        str(deleting).lower(),
        created
    ]))
'
    )

    if [[ "$SCENARIO" != scenario-e ]]; then
        OK=false
        if clinical; then OK=true; fi
    else
        # Mark this timestamp as having successful Pod observation.
        printf '%s,%s,%s\n' "$(utc)" "$OK" true >> "$RUN/e-clinical-observations.csv"
    fi

    QUALIFYING=()
    READY_COUNT=0
    ORIGINAL_READY=false
    ORIGINAL_PRESENT=false
    REPLACEMENT_READY=false
    CURRENT_REPLACEMENT=''

    for STATE in "${STATES[@]}"; do

        IFS='|' read -r PN NN PH RD DELETING CREATED <<< "$STATE"

        printf '%s,%s,%s,%s,%s,%s\n' \
            "$(utc)" "$PN" "$NN" "$PH" "$RD" "$OK" \
            >> "$RUN/recovery-observations.csv"

        if [[ "$PN" == "$ORIGINAL" ]]; then
            ORIGINAL_PRESENT=true
        fi

        if [[ "$PN" != "$ORIGINAL" &&
              "$NN" != "$ORIGINAL_NODE" &&
              "$DELETING" == false ]]; then

            if [[ "$REPLACEMENT_CREATED_RECORDED" == false ]]; then
                printf '%s\n' "$CREATED" \
                    > "$RUN/replacement-created-time.txt"
                printf '%s\n' "$PN" \
                    > "$RUN/first-replacement-pod.txt"
                REPLACEMENT_CREATED_RECORDED=true
            fi
        fi

        if [[ "$PH" == Running &&
              "$RD" == true &&
              "$DELETING" == false ]]; then

            READY_COUNT=$((READY_COUNT + 1))

            if [[ "$PN" == "$ORIGINAL" ]]; then
                ORIGINAL_READY=true
            fi

            if [[ "$PN" != "$ORIGINAL" &&
                  "$NN" != "$ORIGINAL_NODE" ]]; then

                QUALIFYING+=("$PN")

                if [[ "$FIRST_READY_RECORDED" == false ]]; then
                    utc > "$RUN/replacement-ready-observed-time.txt"
                    FIRST_READY_RECORDED=true
                fi
            fi
        fi
    done

    if [[ "$SCENARIO" == scenario-e ]]; then
        # Observe the full fixed-duration degradation and continue
        # observing after fault clearance until clinical stability or
        # the predeclared post-clear deadline. Do not confuse an
        # adverse clinical outcome with an instrumentation failure.
        if [[ "$OK" != true ]]; then
            E_HAD_CLINICAL_FAILURE=true
            E_STABLE_START=-1
        fi

        if [[ "$FAULT_CLEARED" == true ]]; then
            if [[ "$OK" == true ]]; then
                if [[ "$E_FIRST_POST_CLEAR_HEALTH" == false ]]; then
                    utc > "$RUN/e-first-post-clear-health-time.txt"
                    E_FIRST_POST_CLEAR_HEALTH=true
                fi
                if (( E_STABLE_START < 0 )); then
                    E_STABLE_START=$SECONDS
                fi
                if (( SECONDS - E_STABLE_START >= E_CLINICAL_STABILITY_SECONDS )); then
                    E_CLINICAL_STABLE=true
                    utc > "$RUN/e-clinical-stability-confirmed-time.txt"
                    log "Scenario E clinical health stable for ${E_CLINICAL_STABILITY_SECONDS}s after clearance"
                    break
                fi
            else
                E_STABLE_START=-1
            fi
        fi

        sleep 3
        continue
    fi

    CURRENT_VALID=false

    if [[ "$OK" == true &&
          "$READY_COUNT" -eq 1 &&
          "$ORIGINAL_READY" == false &&
          "${#QUALIFYING[@]}" -eq 1 ]]; then

        CURRENT_VALID=true
        CURRENT_REPLACEMENT="${QUALIFYING[0]}"
    fi

    if [[ "$CURRENT_VALID" == true ]]; then

        if [[ "$FIRST_RECOVERY_RECORDED" == false ]]; then

            utc > "$RUN/clinical-restored-observed-time.txt"
            FIRST_RECOVERY_RECORDED=true

            if [[ "$FAULT_CLEARED" == true ]]; then
                RECOVERY_OUTCOME="RECOVERY_AFTER_CLEAR"
            else
                RECOVERY_OUTCOME="RECOVERY_DURING_FAULT"
            fi

            printf '%s\n' "$RECOVERY_OUTCOME" \
                > "$RUN/recovery-outcome.txt"

            log "First qualifying replacement recovery: $CURRENT_REPLACEMENT ($RECOVERY_OUTCOME)"
        fi

        if [[ "$RECOVERY_STABLE_START" -lt 0 ||
              "$REPLACEMENT" != "$CURRENT_REPLACEMENT" ]]; then

            RECOVERY_STABLE_START=$SECONDS
            REPLACEMENT="$CURRENT_REPLACEMENT"

            log "Recovery stability started: $REPLACEMENT"
        fi

        STABLE_SECONDS=$((SECONDS - RECOVERY_STABLE_START))

    else

        if [[ "$RECOVERY_STABLE_START" -ge 0 ]]; then
            log "Recovery stability interrupted"
        fi

        RECOVERY_STABLE_START=-1
        STABLE_SECONDS=0
    fi

    printf '%s,%s,%s,%s,%s\n' \
        "$(utc)" \
        "$CURRENT_REPLACEMENT" \
        "$CURRENT_VALID" \
        "$STABLE_SECONDS" \
        "$FAULT_CLEARED" \
        >> "$RUN/recovery-stability.csv"

    # Recovery-triggered fault clearance.
    if [[ "$CURRENT_VALID" == true &&
          "$FAULT_CLEARED" != true ]] &&
       (( STABLE_SECONDS >= C_RECOVERY_STABILITY_SECONDS )); then

        RECOVERY_STABILITY_CONFIRMED=true

        utc > "$RUN/recovery-stability-confirmed-time.txt"

        log "Recovery stable for ${STABLE_SECONDS}s while fault active"

        release_fault "RECOVERY_STABLE"

        # Start post-clear observation at the next successful
        # observation, not before clearance.
        POST_CLEAR_START=-1
    fi

    # Continue observing after clearance, even when replacement
    # readiness or clinical health is temporarily unavailable.
    if [[ "$FAULT_CLEARED" == true ]]; then

        if [[ "$CURRENT_VALID" == true ]]; then

            if [[ "$POST_CLEAR_START" -lt 0 ]]; then
                POST_CLEAR_START=$SECONDS
                log "Post-clear stability observation started"
            fi

            if (( SECONDS - POST_CLEAR_START >= C_POST_FAULT_SECONDS )); then

                RESTORED=true

                utc > "$RUN/post-clear-stability-confirmed-time.txt"

                log "Post-clear replacement stable for ${C_POST_FAULT_SECONDS}s"
                break
            fi

        else
            # Do not fail immediately. Reset the stability timer
            # and continue observing until the recovery deadline.
            if [[ "$POST_CLEAR_START" -ge 0 ]]; then
                log "Post-clear stability interrupted; restarting timer"
            fi

            POST_CLEAR_START=-1
        fi
    fi

    sleep 3
done

# Clear any remaining fault when the observation deadline is reached.
if [[ "$FAULT_CLEARED" != true ]]; then
    release_fault "OBSERVATION_DEADLINE"
fi

if [[ "$SCENARIO" == scenario-c ]]; then

    if [[ "$RESTORED" != true ]]; then

        if [[ "$FIRST_RECOVERY_RECORDED" == true ]]; then
            printf '%s\n' "RECOVERY_UNSTABLE" \
                > "$RUN/recovery-outcome.txt"
        elif [[ "$FAULT_CLEAR_REASON" == MAX_FAULT_DURATION ]]; then
            printf '%s\n' "NO_VERIFIED_REPLACEMENT_RECOVERY" \
                > "$RUN/recovery-outcome.txt"
        else
            printf '%s\n' "RECOVERY_TIMEOUT" \
                > "$RUN/recovery-outcome.txt"
        fi

        fail "Replacement recovery not stable within timeout"
    fi

    [[ -n "$REPLACEMENT" ]] ||
        fail "No qualifying replacement Pod recorded"

    printf '%s\n' "$REPLACEMENT" \
        > "$RUN/replacement-pod.txt"

else
    # Scenario E: fault clearance and completed observation are
    # distinct from the clinical outcome. Always preserve failures.
    if [[ "$E_CLINICAL_STABLE" == true ]]; then
        if [[ "$E_HAD_CLINICAL_FAILURE" == true ]]; then
            RECOVERY_OUTCOME="CLINICAL_RESTORED_STABLE"
        else
            RECOVERY_OUTCOME="NO_OBSERVED_CLINICAL_OUTAGE"
        fi
    else
        RECOVERY_OUTCOME="CLINICAL_NOT_RESTORED"
    fi
    printf '%s\n' "$RECOVERY_OUTCOME" > "$RUN/recovery-outcome.txt"
    printf 'outcome=%s\nclinical_failure_observed=%s\nclinical_stable=%s\n' \
        "$RECOVERY_OUTCOME" "$E_HAD_CLINICAL_FAILURE" "$E_CLINICAL_STABLE" \
        > "$RUN/e-outcome.env"
    log "Scenario E observation outcome: $RECOVERY_OUTCOME"
fi

if [[ "$SCENARIO" == scenario-c ]]; then
    clinical || fail "Clinical service unhealthy at end"
fi

snapshot after

COMPLETE=true

log "Observation completed; readiness and clinical results recorded"
