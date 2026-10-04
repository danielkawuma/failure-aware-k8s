#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

TEST="${1:-}"
OUT_DIR="${2:-}"

[[ -n "$TEST" ]] || die "usage: $0 <reliability|resource|availability|recover> <result-dir>"
[[ -n "$OUT_DIR" ]] || die "result directory is required"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/COMPLETE" "$OUT_DIR/FAILED"

TEST_START="$(timestamp)"
echo "$TEST_START" > "$OUT_DIR/started_at.txt"

cleanup_on_exit() {
  local rc=$?
  stop_controller
  cleanup_faults
  cleanup_pressure
  cleanup_candidates
  wait_node_ready "$FAULT_NODE" || true
  pin_baseline_to_fault_node || true

  if (( rc != 0 )); then
    echo "$(timestamp)" > "$OUT_DIR/FAILED"
  fi
}
trap cleanup_on_exit EXIT INT TERM

restore_baseline

case "$TEST" in
  reliability)
    ;;
  resource)
    kubectl apply -f "$PRESSURE_MANIFEST" >/dev/null
    kubectl wait -n "$NAMESPACE" \
      --for=condition=Ready pod/worker3-resource-pressure \
      --timeout="${WAIT_POD_SECONDS}s" >/dev/null

    requested="$(kubectl describe node "$CANDIDATE_2" \
      | awk '/^  cpu[[:space:]]/{print $2; exit}')"
    echo "$requested" > "$OUT_DIR/worker3_cpu_request.txt"
    [[ "$requested" == "1950m" ]] || \
      die "expected Worker3 CPU request 1950m, observed: ${requested:-<empty>}"
    ;;
  availability)
    kubectl cordon "$CANDIDATE_2" >/dev/null
    unschedulable="$(kubectl get node "$CANDIDATE_2" -o jsonpath='{.spec.unschedulable}')"
    [[ "$unschedulable" == "true" ]] || die "Worker3 was not successfully cordoned"
    ;;
  recover)
    ;;
  *)
    die "unknown test: $TEST"
    ;;
esac

snapshot "$OUT_DIR/pre-test.txt"

start_controller "$OUT_DIR/controller.log"

case "$TEST" in
  reliability|resource|availability)
    "$FAULT_SCRIPT" scenario-b apply >"$OUT_DIR/fault-apply.log" 2>&1
    wait_log_pattern "$OUT_DIR/controller.log" '\[ENFORCEMENT\].*action=PreserveExisting'
    ;;
  recover)
    ORIGINAL_POD="$(kubectl get pods -n "$NAMESPACE" -l "$APP_SELECTOR" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}')"
    ORIGINAL_POD_IP="$(kubectl get pod -n "$NAMESPACE" "$ORIGINAL_POD" \
      -o jsonpath='{.status.podIP}')"

    [[ -n "$ORIGINAL_POD_IP" ]] || die "could not obtain original baseline Pod IP"

    printf '%s\n' "$ORIGINAL_POD" > "$OUT_DIR/original_pod.txt"
    printf '%s\n' "$ORIGINAL_POD_IP" > "$OUT_DIR/original_pod_ip.txt"

    "$FAULT_SCRIPT" scenario-c apply "$ORIGINAL_POD_IP" >"$OUT_DIR/fault-apply.log" 2>&1
    wait_log_pattern "$OUT_DIR/controller.log" '\[ENFORCEMENT\].*action=RecoveryReleased'
    ;;
esac

case "$TEST" in
  reliability)
    assert_log "$OUT_DIR/controller.log" \
      '\[CANDIDATE\] node=k3s-worker2 \| eligible=true' \
      "Worker2 should be eligible"
    assert_log "$OUT_DIR/controller.log" \
      '\[CANDIDATE\] node=k3s-worker3 \| eligible=true' \
      "Worker3 should be eligible"
    assert_log "$OUT_DIR/controller.log" \
      '\[CANDIDATE\] node=k3s-worker4 \| eligible=true' \
      "Worker4 should be eligible"
    assert_log "$OUT_DIR/controller.log" \
      '\[SELECTION\] selected=k3s-worker3 ' \
      "Worker3 should be selected when all candidates are feasible"
    assert_log "$OUT_DIR/controller.log" \
      '\[DECISION\].*decision=Preserve' \
      "Scenario B should end in PRESERVE"
    ;;

  resource)
    assert_log "$OUT_DIR/controller.log" \
      '\[CANDIDATE\] node=k3s-worker3 \| eligible=false .*requested_cpu=1950m .*remaining_cpu=50m .*required_cpu=100m' \
      "Worker3 should be resource-ineligible with only 50m remaining CPU"
    assert_log "$OUT_DIR/controller.log" \
      '\[SELECTION\] selected=k3s-worker4 ' \
      "Worker4 should be selected after Worker3 resource exclusion"
    assert_log "$OUT_DIR/controller.log" \
      '\[DECISION\].*decision=Preserve' \
      "Scenario B should end in PRESERVE"
    ;;

  availability)
    assert_log "$OUT_DIR/controller.log" \
      '\[CANDIDATE\] node=k3s-worker3 \| eligible=false \| Ready=true \| schedulable=false' \
      "Worker3 should be excluded while cordoned"
    assert_log "$OUT_DIR/controller.log" \
      '\[SELECTION\] selected=k3s-worker4 ' \
      "Worker4 should be selected after Worker3 availability exclusion"
    assert_log "$OUT_DIR/controller.log" \
      '\[DECISION\].*decision=Preserve' \
      "Scenario B should end in PRESERVE"
    ;;

  recover)
    assert_log "$OUT_DIR/controller.log" \
      '\[SELECTION\] selected=k3s-worker3 ' \
      "Worker3 should be selected for recovery"
    assert_log "$OUT_DIR/controller.log" \
      '\[DECISION\].*decision=Recover' \
      "Scenario C should emit RECOVER"
    assert_log "$OUT_DIR/controller.log" \
      '\[PLACEMENT\].*selected_candidate=k3s-worker3' \
      "placement constraint should target Worker3"
    assert_log "$OUT_DIR/controller.log" \
      '\[ENFORCEMENT\].*action=RecoveryReleased.*selected recovery candidate k3s-worker3' \
      "enforcement should release recovery to Worker3"

    wait_pod_on_node "$EXPECTED_PRIMARY"

    NEW_POD="$(kubectl get pods -n "$NAMESPACE" -l "$APP_SELECTOR" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}')"
    NEW_NODE="$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
      -o jsonpath='{.spec.nodeName}')"

    printf '%s\n' "$NEW_POD" > "$OUT_DIR/replacement_pod.txt"
    printf '%s\n' "$NEW_NODE" > "$OUT_DIR/replacement_node.txt"

    [[ "$NEW_POD" != "$(cat "$OUT_DIR/original_pod.txt")" ]] || \
      die "replacement Pod name did not change"
    [[ "$NEW_NODE" == "$EXPECTED_PRIMARY" ]] || \
      die "replacement landed on $NEW_NODE instead of $EXPECTED_PRIMARY"

    selector="$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
      -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}')"
    printf '%s\n' "$selector" > "$OUT_DIR/enforced_hostname_selector.txt"
    [[ "$selector" == "$EXPECTED_PRIMARY" ]] || \
      die "Deployment hostname selector is $selector instead of $EXPECTED_PRIMARY"
    ;;
esac

snapshot "$OUT_DIR/post-condition.txt"

{
  echo "test=$TEST"
  echo "started_at=$TEST_START"
  echo "completed_at=$(timestamp)"
  case "$TEST" in
    reliability)
      echo "expected_selected=$EXPECTED_PRIMARY"
      echo "expected_decision=Preserve"
      ;;
    resource|availability)
      echo "expected_selected=$EXPECTED_FALLBACK"
      echo "expected_decision=Preserve"
      ;;
    recover)
      echo "expected_selected=$EXPECTED_PRIMARY"
      echo "expected_decision=Recover"
      echo "replacement_node=$(cat "$OUT_DIR/replacement_node.txt")"
      ;;
  esac
  echo "status=PASS"
} > "$OUT_DIR/result.env"

touch "$OUT_DIR/COMPLETE"
echo "PASS: $TEST"
