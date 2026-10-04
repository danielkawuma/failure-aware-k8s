#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

NAMESPACE="${NAMESPACE:-failure-aware}"
DEPLOYMENT="${DEPLOYMENT:-baseline-web}"
APP_SELECTOR="${APP_SELECTOR:-app=baseline-web}"

FAULT_NODE="${FAULT_NODE:-k3s-worker1}"
CANDIDATE_1="${CANDIDATE_1:-k3s-worker2}"
CANDIDATE_2="${CANDIDATE_2:-k3s-worker3}"
CANDIDATE_3="${CANDIDATE_3:-k3s-worker4}"

EXPECTED_PRIMARY="${EXPECTED_PRIMARY:-k3s-worker3}"
EXPECTED_FALLBACK="${EXPECTED_FALLBACK:-k3s-worker4}"

CONTROLLER_BIN="${CONTROLLER_BIN:-$REPO_ROOT/controller/target/debug/failure-aware-controller}"
FAULT_SCRIPT="${FAULT_SCRIPT:-$REPO_ROOT/scripts/fault.sh}"
PRESSURE_MANIFEST="${PRESSURE_MANIFEST:-$REPO_ROOT/workloads/candidate-selection/worker3-resource-pressure.yaml}"

WAIT_READY_SECONDS="${WAIT_READY_SECONDS:-180}"
WAIT_CONTROLLER_SECONDS="${WAIT_CONTROLLER_SECONDS:-240}"
WAIT_POD_SECONDS="${WAIT_POD_SECONDS:-180}"

CTRL_PID=""

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

assert_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

node_ready() {
  local node="$1"
  kubectl get node "$node" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null
}

wait_node_ready() {
  local node="$1"
  local deadline=$((SECONDS + WAIT_READY_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$(node_ready "$node")" == "True" ]]; then
      return 0
    fi
    sleep 2
  done
  die "node $node did not become Ready within ${WAIT_READY_SECONDS}s"
}

wait_pod_on_node() {
  local node="$1"
  local deadline=$((SECONDS + WAIT_POD_SECONDS))
  while (( SECONDS < deadline )); do
    local actual
    actual="$(kubectl get pods -n "$NAMESPACE" -l "$APP_SELECTOR" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
    if [[ "$actual" == "$node" ]]; then
      return 0
    fi
    sleep 2
  done
  kubectl get pods -n "$NAMESPACE" -l "$APP_SELECTOR" -o wide || true
  die "baseline workload did not become Running on $node within ${WAIT_POD_SECONDS}s"
}

ensure_no_controller_running() {
  if pgrep -f '[f]ailure-aware-controller' >/dev/null 2>&1; then
    die "a failure-aware-controller process is already running; stop it before starting the campaign"
  fi
}

start_controller() {
  local log_file="$1"
  : > "$log_file"
  (
    cd "$REPO_ROOT"
    exec stdbuf -oL -eL "$CONTROLLER_BIN"
  ) >"$log_file" 2>&1 &
  CTRL_PID=$!

  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if grep -Fq "[LISTENER] Initial node state synchronized" "$log_file"; then
      return 0
    fi
    if ! kill -0 "$CTRL_PID" 2>/dev/null; then
      cat "$log_file" >&2 || true
      die "controller exited before listener initialization"
    fi
    sleep 1
  done

  cat "$log_file" >&2 || true
  die "controller did not initialize within 20s"
}

stop_controller() {
  if [[ -n "${CTRL_PID:-}" ]] && kill -0 "$CTRL_PID" 2>/dev/null; then
    kill -INT "$CTRL_PID" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$CTRL_PID" 2>/dev/null || break
      sleep 1
    done
    kill -TERM "$CTRL_PID" 2>/dev/null || true
    wait "$CTRL_PID" 2>/dev/null || true
  fi
  CTRL_PID=""
}

wait_log_pattern() {
  local log_file="$1"
  local pattern="$2"
  local deadline=$((SECONDS + WAIT_CONTROLLER_SECONDS))
  while (( SECONDS < deadline )); do
    if grep -Eq "$pattern" "$log_file"; then
      return 0
    fi
    if [[ -n "${CTRL_PID:-}" ]] && ! kill -0 "$CTRL_PID" 2>/dev/null; then
      cat "$log_file" >&2 || true
      die "controller exited while waiting for: $pattern"
    fi
    sleep 2
  done
  cat "$log_file" >&2 || true
  die "timed out waiting for controller log pattern: $pattern"
}

assert_log() {
  local log_file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$log_file"; then
    echo "ASSERTION FAILED: $message" >&2
    echo "Expected regex: $pattern" >&2
    echo "--- controller log ---" >&2
    cat "$log_file" >&2 || true
    return 1
  fi
}

snapshot() {
  local output="$1"
  {
    echo "=== TIME ==="
    timestamp
    echo
    echo "=== NODES ==="
    kubectl get nodes -L experiment-role,failure-aware.io/role
    echo
    echo "=== BASELINE PODS ==="
    kubectl get pods -n "$NAMESPACE" -l "$APP_SELECTOR" -o wide
    echo
    echo "=== DEPLOYMENT NODESELECTOR ==="
    kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
      -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
    echo
    echo "=== CANDIDATE ALLOCATED RESOURCES ==="
    for node in "$CANDIDATE_1" "$CANDIDATE_2" "$CANDIDATE_3"; do
      echo "--- $node ---"
      kubectl describe node "$node" | sed -n '/Allocated resources:/,/Events:/p'
    done
  } > "$output"
}

pin_baseline_to_fault_node() {
  kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$FAULT_NODE\"}}}}}" \
    >/dev/null

  kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" \
    --timeout="${WAIT_POD_SECONDS}s" >/dev/null
  wait_pod_on_node "$FAULT_NODE"
}

cleanup_faults() {
  "$FAULT_SCRIPT" clear-all >/dev/null 2>&1 || true
}

cleanup_pressure() {
  kubectl delete -f "$PRESSURE_MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
}

cleanup_candidates() {
  kubectl uncordon "$CANDIDATE_1" >/dev/null 2>&1 || true
  kubectl uncordon "$CANDIDATE_2" >/dev/null 2>&1 || true
  kubectl uncordon "$CANDIDATE_3" >/dev/null 2>&1 || true
}

restore_baseline() {
  stop_controller
  cleanup_faults
  cleanup_pressure
  cleanup_candidates
  wait_node_ready "$FAULT_NODE"
  pin_baseline_to_fault_node
}

preflight() {
  require_cmd kubectl
  require_cmd grep
  require_cmd sed
  require_cmd stdbuf
  require_cmd pgrep
  assert_file "$CONTROLLER_BIN"
  assert_file "$FAULT_SCRIPT"
  assert_file "$PRESSURE_MANIFEST"
  ensure_no_controller_running

  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

  for node in "$FAULT_NODE" "$CANDIDATE_1" "$CANDIDATE_2" "$CANDIDATE_3"; do
    kubectl get node "$node" >/dev/null 2>&1 || die "node not found: $node"
  done

  local role
  for node in "$CANDIDATE_1" "$CANDIDATE_2" "$CANDIDATE_3"; do
    role="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.failure-aware\.io/role}')"
    [[ "$role" == "recovery-candidate" ]] || \
      die "$node does not have failure-aware.io/role=recovery-candidate"
  done

  restore_baseline
}
