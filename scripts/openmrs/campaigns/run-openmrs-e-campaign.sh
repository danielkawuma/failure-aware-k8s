#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# ============================================================
# Configuration
# ============================================================

RUNNER="$ROOT/scripts/run-openmrs-integrated.sh"
FAULT="$ROOT/scripts/fault.sh"
RESET="$ROOT/scripts/openmrs-backend-reset.sh"
MODE_PREP="$ROOT/scripts/openmrs-mode-prepare.sh"

MODES_CSV="${MODES:-V0,T5,T10,T30,FA1}"
PROFILES_CSV="${OPENMRS_E_PROFILES:-mild,moderate,severe}"

RUNS="${RUNS_PER_MODE:-2}"
START="${START_RUN:-3}"

PAUSE="${RESET_SECONDS:-60}"
RUN_TIMEOUT="${RUN_TIMEOUT_SECONDS:-2400}"

CAMPAIGN_BASE="$ROOT/experiments/evaluation/openmrs/campaigns"
CAMPAIGN="$CAMPAIGN_BASE/e-$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$CAMPAIGN"

exec > >(tee -a "$CAMPAIGN/campaign.log") 2>&1

SUMMARY="$CAMPAIGN/summary.csv"
PLAN="$CAMPAIGN/plan.csv"

printf 'profile,mode,run,status,started,finished,exit_code\n' > "$SUMMARY"
printf 'profile,mode,run\n' > "$PLAN"

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
    local profile="$1"
    local mode="$2"
    local id="$3"

    printf '%s/experiments/evaluation/openmrs/scenario-e/%s/%s/run-%s\n' \
        "$ROOT" "$profile" "$mode" "$id"
}

run_complete() {
    local dir="$1"

    [[ -f "$dir/COMPLETE" &&
       ! -e "$dir/INCOMPLETE" ]]
}

check_fault_clear() {
    local output

    output="$(
        timeout 25 "$FAULT" scenario-e show </dev/null 2>&1
    )" || return 1

    grep -Eq '^none$' <<< "$output"
}

record_summary() {
    local profile="$1"
    local mode="$2"
    local id="$3"
    local status="$4"
    local started="$5"
    local finished="$6"
    local rc="$7"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$profile" \
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

for value in "$RUNS" "$START" "$PAUSE" "$RUN_TIMEOUT"; do
    [[ "$value" =~ ^[0-9]+$ ]] ||
        fail "Invalid numeric setting: $value"
done

(( RUNS > 0 )) ||
    fail "RUNS_PER_MODE must be positive"

(( RUN_TIMEOUT > 0 )) ||
    fail "RUN_TIMEOUT_SECONDS must be positive"

[[ -x "$RUNNER" &&
   -x "$FAULT" &&
   -x "$RESET" &&
   -x "$MODE_PREP" ]] ||
    fail "Runner, fault or reset script missing/not executable"

[[ -f "${SSH_KEY:-$HOME/.ssh/k8s-aware}" ]] ||
    fail "SSH key missing"

IFS=',' read -r -a MODE_ARRAY <<< "$MODES_CSV"
IFS=',' read -r -a PROFILE_ARRAY <<< "$PROFILES_CSV"

(( ${#MODE_ARRAY[@]} > 0 )) ||
    fail "No modes specified"

(( ${#PROFILE_ARRAY[@]} > 0 )) ||
    fail "No profiles specified"

for mode in "${MODE_ARRAY[@]}"; do
    case "$mode" in
        V0|T5|T10|T30|FA1)
            ;;
        *)
            fail "Invalid mode: $mode"
            ;;
    esac
done

for profile in "${PROFILE_ARRAY[@]}"; do
    case "$profile" in
        mild|moderate|severe)
            ;;
        *)
            fail "Invalid profile: $profile"
            ;;
    esac
done

# Reject duplicate configuration entries.
if (( ${#MODE_ARRAY[@]} != $(printf '%s\n' "${MODE_ARRAY[@]}" | sort -u | wc -l) )); then
    fail "Duplicate modes are not allowed"
fi

if (( ${#PROFILE_ARRAY[@]} != $(printf '%s\n' "${PROFILE_ARRAY[@]}" | sort -u | wc -l) )); then
    fail "Duplicate profiles are not allowed"
fi

# ============================================================
# Generate complete campaign plan
# ============================================================

log "Generating Scenario E campaign plan"

for ((i=0; i<RUNS; i++)); do

    id="$(printf '%03d' "$((10#$START+i))")"

    # Randomize the order of modes for each logical run ID.
    mapfile -t ORDER < <(
        printf '%s\n' "${MODE_ARRAY[@]}" | shuf
    )

    for mode in "${ORDER[@]}"; do

        for profile in "${PROFILE_ARRAY[@]}"; do

            printf '%s,%s,%s\n' \
                "$profile" "$mode" "$id" >> "$PLAN"

        done

    done

done

# ============================================================
# IMPORTANT FIX:
# Load the complete plan into memory.
#
# Child processes must not consume plan rows.
# ============================================================

mapfile -t PLAN_ROWS < "$PLAN"

EXPECTED_ROWS=$(( ${#PLAN_ROWS[@]} - 1 ))

EXPECTED_MATRIX=$(( ${#MODE_ARRAY[@]} * ${#PROFILE_ARRAY[@]} * RUNS ))

[[ "$EXPECTED_ROWS" -eq "$EXPECTED_MATRIX" ]] ||
    fail "Plan generation mismatch: expected $EXPECTED_MATRIX, found $EXPECTED_ROWS"

log "Scenario E plan: $PLAN"
log "Planned experiments: $EXPECTED_ROWS"

# ============================================================
# Plan-only mode
# ============================================================

if [[ "${OPENMRS_CAMPAIGN_EXECUTE:-false}" != true ]]; then
    log "PLAN ONLY: no faults injected"
    exit 0
fi

[[ "${OPENMRS_ENABLE_FAULTS:-false}" == true ]] ||
    fail "Fault execution not enabled"

# ============================================================
# Execute all planned experiments
# ============================================================

for row in "${PLAN_ROWS[@]}"; do

    # Skip CSV header.
    [[ "$row" == "profile,mode,run" ]] && continue

    IFS=',' read -r profile mode id <<< "$row"

    [[ -n "$profile" &&
       -n "$mode" &&
       -n "$id" ]] ||
        fail "Malformed campaign plan row: $row"

    dir="$(result_dir "$profile" "$mode" "$id")"

    # --------------------------------------------------------
    # Resume completed runs
    # --------------------------------------------------------

    if [[ -e "$dir" ]]; then

        if run_complete "$dir"; then

            log "SKIP completed: $profile/$mode/$id"

            now="$(utc)"

            record_summary \
                "$profile" \
                "$mode" \
                "$id" \
                "SKIPPED_COMPLETE" \
                "$now" \
                "$now" \
                0

            continue
        fi

        fail "Existing incomplete or ambiguous run (preserved): $dir"
    fi

    # --------------------------------------------------------
    # Confirm clean fault state
    # --------------------------------------------------------

    check_fault_clear ||
        fail "Scenario E fault not confirmed cleared"

    log "=============================================="
    log "PREPARING $profile/$mode/$id"
    log "=============================================="

    # --------------------------------------------------------
    # Configure experimental mode
    # --------------------------------------------------------

    "$MODE_PREP" "$mode" </dev/null ||
        fail "Mode preparation failed: $mode"

    # --------------------------------------------------------
    # Restore backend to Worker1
    # --------------------------------------------------------

    "$RESET" </dev/null ||
        fail "Backend placement reset failed"

    # --------------------------------------------------------
    # Verify effective tolerations
    # --------------------------------------------------------

    "$MODE_PREP" "$mode" </dev/null ||
        fail "Effective tolerations changed after reset: $mode"

    # --------------------------------------------------------
    # Execute experiment
    # --------------------------------------------------------

    started="$(utc)"

    log "START $profile/$mode/$id"

    rc=0

    timeout \
        --signal=TERM \
        --kill-after=30s \
        "${RUN_TIMEOUT}s" \
        "$RUNNER" \
        scenario-e \
        "$mode" \
        "$id" \
        "$profile" </dev/null || rc=$?

    finished="$(utc)"

    status="FAILED"

    if (( rc == 0 )) &&
       run_complete "$dir" &&
       check_fault_clear; then

        status="OBSERVATION_COMPLETE"

    fi

    record_summary \
        "$profile" \
        "$mode" \
        "$id" \
        "$status" \
        "$started" \
        "$finished" \
        "$rc"

    [[ "$status" == "OBSERVATION_COMPLETE" ]] ||
        fail "Run failed: $profile/$mode/$id (exit=$rc)"

    log "COMPLETE $profile/$mode/$id"

    # --------------------------------------------------------
    # Pause before next experiment
    # --------------------------------------------------------

    sleep "$PAUSE"

done

# ============================================================
# Final completion audit
# ============================================================

log "=============================================="
log "FINAL SCENARIO E COMPLETION AUDIT"
log "=============================================="

completed=0
missing=0
audited=0

for row in "${PLAN_ROWS[@]}"; do

    [[ "$row" == "profile,mode,run" ]] && continue

    IFS=',' read -r profile mode id <<< "$row"

    audited=$((audited + 1))

    dir="$(result_dir "$profile" "$mode" "$id")"

    if run_complete "$dir"; then

        completed=$((completed + 1))

    else

        missing=$((missing + 1))

        log "MISSING OR INCOMPLETE: $profile/$mode/$id"

    fi

done

log "Planned: $EXPECTED_ROWS"
log "Audited: $audited"
log "Completed: $completed"
log "Missing/incomplete: $missing"

[[ "$audited" -eq "$EXPECTED_ROWS" ]] ||
    fail "Audit count does not match campaign plan"

[[ "$completed" -eq "$EXPECTED_ROWS" ]] ||
    fail "Scenario E incomplete: $completed/$EXPECTED_ROWS"

[[ "$missing" -eq 0 ]] ||
    fail "Scenario E has $missing missing or incomplete runs"

check_fault_clear ||
    fail "Scenario E fault not confirmed cleared after campaign"

log "=============================================="
log "SCENARIO E VERIFIED COMPLETE"
log "=============================================="

log "Campaign observations complete: $CAMPAIGN"
log "Campaign plan: $PLAN"
log "Campaign summary: $SUMMARY"