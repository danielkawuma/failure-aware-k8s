#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# ============================================================
# Configuration
# ============================================================

SCENARIOS="${SCENARIOS:-scenario-b,scenario-c}"
MODES="${MODES:-V0,T5,T10,T30,FA1}"

RUNS="${RUNS_PER_MODE:-2}"
START="${START_RUN:-3}"

PAUSE="${RESET_SECONDS:-60}"
TIMEOUT="${RUN_TIMEOUT_SECONDS:-2400}"

B_RUNNER="$ROOT/scripts/run-openmrs-experiment.sh"
C_RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
CD_RUNNER="$ROOT/scripts/run-openmrs-cd-campaign.sh"
E_RUNNER="$ROOT/scripts/run-openmrs-e-campaign.sh"

RESET="$ROOT/scripts/openmrs-backend-reset.sh"
MODE_PREP="$ROOT/scripts/openmrs-mode-prepare.sh"

CAMPAIGN_BASE="$ROOT/experiments/evaluation/openmrs/campaigns"

OUT="$CAMPAIGN_BASE/$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$OUT"

exec > >(tee -a "$OUT/campaign.log") 2>&1

SUMMARY="$OUT/summary.csv"
PLAN="$OUT/plan.csv"

printf 'scenario,mode,run,status,start_utc,end_utc,exit_code\n' \
    > "$SUMMARY"

printf 'scenario,mode,run\n' > "$PLAN"

# ============================================================
# Helpers
# ============================================================

utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
    printf '[%s] %s\n' "$(utc)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

result_dir() {
    local scenario="$1"
    local mode="$2"
    local id="$3"

    printf '%s/experiments/evaluation/openmrs/%s/%s/run-%s\n' \
        "$ROOT" "$scenario" "$mode" "$id"
}

run_complete() {
    local dir="$1"

    [[ -f "$dir/COMPLETE" &&
       ! -e "$dir/INCOMPLETE" ]]
}

record_summary() {
    local scenario="$1"
    local mode="$2"
    local id="$3"
    local status="$4"
    local started="$5"
    local finished="$6"
    local rc="$7"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$scenario" \
        "$mode" \
        "$id" \
        "$status" \
        "$started" \
        "$finished" \
        "$rc" >> "$SUMMARY"
}

# ============================================================
# Validate configuration
# ============================================================

for value in "$RUNS" "$START" "$PAUSE" "$TIMEOUT"; do
    [[ "$value" =~ ^[0-9]+$ ]] ||
        fail "Invalid numeric setting: $value"
done

(( RUNS > 0 )) ||
    fail "RUNS_PER_MODE must be positive"

(( TIMEOUT > 0 )) ||
    fail "RUN_TIMEOUT_SECONDS must be positive"

IFS=',' read -r -a SCENARIO_ARRAY <<< "$SCENARIOS"
IFS=',' read -r -a MODE_ARRAY <<< "$MODES"

(( ${#SCENARIO_ARRAY[@]} > 0 )) ||
    fail "No scenarios specified"

(( ${#MODE_ARRAY[@]} > 0 )) ||
    fail "No modes specified"

for scenario in "${SCENARIO_ARRAY[@]}"; do
    case "$scenario" in
        scenario-b|scenario-c|scenario-c-d|scenario-e)
            ;;
        *)
            fail "Unsupported scenario: $scenario"
            ;;
    esac
done

for mode in "${MODE_ARRAY[@]}"; do
    case "$mode" in
        V0|T5|T10|T30|FA1)
            ;;
        *)
            fail "Unsupported mode: $mode"
            ;;
    esac
done

# ============================================================
# Generate complete campaign plan
# ============================================================

log "Generating campaign plan"

for scenario in "${SCENARIO_ARRAY[@]}"; do

    for ((i=0; i<RUNS; i++)); do

        id="$(printf '%03d' "$((10#$START+i))")"

        case "$scenario" in

            scenario-c-d)
                printf '%s,%s,%s\n' \
                    "$scenario" FA1 "$id" >> "$PLAN"
                ;;

            scenario-e)
                printf '%s,%s,%s\n' \
                    "$scenario" DELEGATED "$id" >> "$PLAN"
                ;;

            scenario-b|scenario-c)

                mapfile -t ORDER < <(
                    printf '%s\n' "${MODE_ARRAY[@]}" | shuf
                )

                for mode in "${ORDER[@]}"; do

                    printf '%s,%s,%s\n' \
                        "$scenario" "$mode" "$id" >> "$PLAN"

                done
                ;;
        esac

    done

done

log "Campaign plan: $PLAN"

# ============================================================
# IMPORTANT FIX:
# Load plan into memory before executing child scripts.
# ============================================================

mapfile -t PLAN_ROWS < "$PLAN"

EXPECTED_ROWS=$(( ${#PLAN_ROWS[@]} - 1 ))

log "Planned logical rows: $EXPECTED_ROWS"

# ============================================================
# Plan-only mode
# ============================================================

if [[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" != true ]]; then

    log "PLAN ONLY: no faults injected"

    exit 0
fi

# ============================================================
# Execution preflight
# ============================================================

[[ "${OPENMRS_ENABLE_FAULTS:-false}" == true ]] ||
    fail "OPENMRS_ENABLE_FAULTS=true required"

[[ -f "${SSH_KEY:-$HOME/.ssh/k8s-aware}" ]] ||
    fail "SSH key missing"

for scenario in "${SCENARIO_ARRAY[@]}"; do

    case "$scenario" in

        scenario-b)
            [[ -x "$B_RUNNER" &&
               -x "$RESET" &&
               -x "$MODE_PREP" ]] ||
                fail "Scenario B runner/reset missing"
            ;;

        scenario-c)
            [[ -x "$C_RUNNER" &&
               -x "$RESET" &&
               -x "$MODE_PREP" ]] ||
                fail "Scenario C runner/reset missing"
            ;;

        scenario-c-d)
            [[ -x "$CD_RUNNER" ]] ||
                fail "Dedicated C+D runner missing"
            ;;

        scenario-e)
            [[ -x "$E_RUNNER" ]] ||
                fail "Dedicated Scenario E runner missing"
            ;;
    esac

done

# ============================================================
# Execute scenarios sequentially
# ============================================================

for scenario in "${SCENARIO_ARRAY[@]}"; do

    log "=============================================="
    log "Starting scenario: $scenario"
    log "=============================================="

    # --------------------------------------------------------
    # Dedicated C+D campaign
    # --------------------------------------------------------

    if [[ "$scenario" == scenario-c-d ]]; then

        log "START dedicated C+D campaign"

        RUNS_PER_MODE="$RUNS" \
        START_RUN="$START" \
        "$CD_RUNNER" </dev/null ||
            fail "C+D campaign failed"

        log "COMPLETE dedicated C+D campaign"

        continue
    fi

    # --------------------------------------------------------
    # Dedicated Scenario E campaign
    # --------------------------------------------------------

    if [[ "$scenario" == scenario-e ]]; then

        log "START dedicated Scenario E campaign"

        RUNS_PER_MODE="$RUNS" \
        START_RUN="$START" \
        MODES="$MODES" \
        "$E_RUNNER" </dev/null ||
            fail "Scenario E campaign failed"

        log "COMPLETE dedicated Scenario E campaign"

        continue
    fi

    # --------------------------------------------------------
    # Scenario B and Scenario C
    # --------------------------------------------------------

    for row in "${PLAN_ROWS[@]}"; do

        IFS=',' read -r planned mode id <<< "$row"

        [[ "$planned" == "$scenario" ]] || continue

        dir="$(result_dir "$scenario" "$mode" "$id")"

        # ----------------------------------------------------
        # Resume existing completed experiments
        # ----------------------------------------------------

        if [[ -e "$dir" ]]; then

            if run_complete "$dir"; then

                log "SKIP completed: $scenario/$mode/$id"

                now="$(utc)"

                record_summary \
                    "$scenario" \
                    "$mode" \
                    "$id" \
                    "SKIPPED_COMPLETE" \
                    "$now" \
                    "$now" \
                    0

                continue
            fi

            fail "Existing incomplete or ambiguous run: $dir"
        fi

        log "=============================================="
        log "PREPARING $scenario/$mode/$id"
        log "=============================================="

        # ----------------------------------------------------
        # Configure benchmark mode
        # ----------------------------------------------------

        "$MODE_PREP" "$mode" </dev/null ||
            fail "Mode preparation failed: $mode"

        # ----------------------------------------------------
        # Restore backend to expected original worker
        # ----------------------------------------------------

        "$RESET" </dev/null ||
            fail "Backend reset failed"

        # ----------------------------------------------------
        # Verify tolerations after reset
        # ----------------------------------------------------

        "$MODE_PREP" "$mode" </dev/null ||
            fail "Effective tolerations changed after reset: $mode"

        # ----------------------------------------------------
        # Execute experiment
        # ----------------------------------------------------

        started="$(utc)"

        log "START $scenario/$mode/$id"

        rc=0

        if [[ "$scenario" == scenario-b ]]; then

            timeout \
                --signal=TERM \
                --kill-after=30s \
                "${TIMEOUT}s" \
                "$B_RUNNER" \
                scenario-b \
                "$mode" \
                "$id" </dev/null || rc=$?

        else

            timeout \
                --signal=TERM \
                --kill-after=30s \
                "${TIMEOUT}s" \
                "$C_RUNNER" \
                scenario-c \
                "$mode" \
                "$id" </dev/null || rc=$?

        fi

        finished="$(utc)"

        status="FAILED"

        if (( rc == 0 )) && run_complete "$dir"; then
            status="OBSERVATION_COMPLETE"
        fi

        record_summary \
            "$scenario" \
            "$mode" \
            "$id" \
            "$status" \
            "$started" \
            "$finished" \
            "$rc"

        [[ "$status" == OBSERVATION_COMPLETE ]] ||
            fail "Experiment failed: $scenario/$mode/$id"

        log "COMPLETE $scenario/$mode/$id"

        # ----------------------------------------------------
        # Wait before next experiment
        # ----------------------------------------------------

        sleep "$PAUSE"

    done

    # ========================================================
    # FINAL SCENARIO COMPLETION AUDIT
    # ========================================================

    log "Auditing completed runs for $scenario"

    expected=0
    completed=0

    for row in "${PLAN_ROWS[@]}"; do

        IFS=',' read -r planned mode id <<< "$row"

        [[ "$planned" == "$scenario" ]] || continue

        expected=$((expected + 1))

        dir="$(result_dir "$scenario" "$mode" "$id")"

        if run_complete "$dir"; then

            completed=$((completed + 1))

        else

            log "MISSING OR INCOMPLETE: $scenario/$mode/$id"

        fi

    done

    log "$scenario completed: $completed/$expected"

    [[ "$completed" -eq "$expected" ]] ||
        fail "Scenario $scenario incomplete: $completed/$expected"

    log "SCENARIO VERIFIED COMPLETE: $scenario"

done

# ============================================================
# Final campaign completion
# ============================================================

log "=============================================="
log "CAMPAIGN COMPLETED SUCCESSFULLY"
log "=============================================="

log "Campaign directory: $OUT"
log "Campaign plan: $PLAN"
log "Campaign summary: $SUMMARY"