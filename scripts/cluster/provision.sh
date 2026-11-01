#!/usr/bin/env bash
# Build the K3s test cluster used in the paper and write a kubeconfig.
# Steps: hostnames, pinned K3s server, worker joins, node labels, the
# failure-aware namespace, optional NFS export, and kubeconfig/cluster.kubeconfig.
# Requires: Ubuntu 24.04 VMs reachable over SSH with passwordless sudo.
# Usage: cp scripts/cluster/cluster.env.example scripts/cluster/cluster.env  (edit)
#        bash scripts/cluster/provision.sh
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
ENV="${CLUSTER_ENV:-$HERE/cluster.env}"
[[ -f "$ENV" ]] || { echo "Missing $ENV (copy cluster.env.example)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
ssh_() { ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$1" "${@:2}"; }
log() { printf '[PROVISION %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

log "server $SERVER_IP: hostname, packages, K3s $K3S_VERSION"
ssh_ "$SERVER_IP" "sudo hostnamectl set-hostname k3s-server && sudo apt-get update -qq && sudo apt-get install -y -qq curl jq iperf3 nfs-common >/dev/null"
ssh_ "$SERVER_IP" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' sh -"
ssh_ "$SERVER_IP" "until sudo k3s kubectl get node k3s-server >/dev/null 2>&1; do sleep 3; done"
TOKEN="$(ssh_ "$SERVER_IP" 'sudo cat /var/lib/rancher/k3s/server/node-token')"

for pair in $WORKERS; do
  name="${pair%%=*}"; ip="${pair##*=}"
  log "worker $name ($ip): hostname, packages, join"
  ssh_ "$ip" "sudo hostnamectl set-hostname $name && sudo apt-get update -qq && sudo apt-get install -y -qq curl jq iperf3 nfs-common >/dev/null"
  ssh_ "$ip" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' K3S_URL='https://$SERVER_IP:6443' K3S_TOKEN='$TOKEN' sh -"
done
unset TOKEN

log "kubeconfig"
mkdir -p "$ROOT/kubeconfig"
ssh_ "$SERVER_IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed "s#https://127.0.0.1:6443#https://$SERVER_IP:6443#" > "$ROOT/kubeconfig/cluster.kubeconfig"
chmod 600 "$ROOT/kubeconfig/cluster.kubeconfig"
export KUBECONFIG="$ROOT/kubeconfig/cluster.kubeconfig"

log "waiting for all nodes to be Ready"
for pair in $WORKERS; do kubectl wait --for=condition=Ready "node/${pair%%=*}" --timeout=300s; done
kubectl label node k3s-worker1 experiment-role=fault-target --overwrite
kubectl label node k3s-worker2 experiment-role=recovery-target --overwrite
kubectl get namespace failure-aware >/dev/null 2>&1 || kubectl create namespace failure-aware

if [[ "${NFS_SETUP:-no}" == yes ]]; then
  log "NFS export $NFS_EXPORT on the server for $NFS_CLIENT_CIDR"
  ssh_ "$SERVER_IP" "sudo apt-get install -y -qq nfs-kernel-server >/dev/null && sudo mkdir -p $NFS_EXPORT && sudo chown nobody:nogroup $NFS_EXPORT && \
    (grep -q '^$NFS_EXPORT ' /etc/exports || echo '$NFS_EXPORT $NFS_CLIENT_CIDR(rw,sync,no_subtree_check)' | sudo tee -a /etc/exports >/dev/null) && sudo exportfs -ra"
fi

log "versions"
kubectl get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status,KUBELET:.status.nodeInfo.kubeletVersion,ROLE:.metadata.labels.experiment-role
log "done; use: export KUBECONFIG=$ROOT/kubeconfig/cluster.kubeconfig"
