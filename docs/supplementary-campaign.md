# Reproducing the Midterm 2 supplementary campaign

This guide reruns the experiments that test hypotheses H1–H5
(`docs/hypotheses-midterm2.md`) on a prepared cluster and regenerates
their tables. The offline reproduction of the earlier results
(`make reproduce`) is separate and needs no cluster.

## 1. Cluster

Build the K3s cluster as described in `docs/testbed.md`:

- Section 3: K3s v1.36.4+k3s1 server and workers.
- Section 7: node labels. Worker2 needs `failure-aware.io/role=recovery-candidate`.
- Section 8: the `failure-aware` namespace.

The campaign expects:

| Node | Role in the campaign |
|---|---|
| `k3s-server` | Control plane |
| `k3s-worker1` | Fault target |
| `k3s-worker2` | Recovery candidate and in-cluster client |
| `k3s-worker3` | Experimental NFS server for the live-writer test |
| `k3s-worker4` | Spare capacity |

Node addresses, the API-server address and the NodePort are set in
`scripts/experiment-config.sh`.

Install the remote helpers:

- **Worker1:** install `scripts/remote/failure-aware-fault.sh` as
  `/usr/local/sbin/failure-aware-fault`, with passwordless `sudo` for
  the SSH user. It applies and clears the partition rules.
- **Worker3:** export `/srv/failure-aware/concurrent-writer` over NFS to
  Worker1 and Worker2, and place a MariaDB 10.11.19 datadir at
  `database/baseline-001`, owned by UID/GID 999.
- **Worker3:** install `scripts/openmrs/concurrent-writer/fence-w2.sh` as
  `/usr/local/sbin/fa-writer-fence-w2`. It drops Worker1's TCP 2049
  traffic.

## 2. Runner host

Use an always-on Linux host that can reach the API server (TCP 6443) and
the workers' NodePort, rather than a laptop that may sleep.

```bash
git clone -b research/repository-consolidation https://github.com/danielkawuma/failure-aware-k8s.git
cd failure-aware-k8s

# kubeconfig for the cluster
mkdir -p ~/.kube && cp <kubeconfig> ~/.kube/config && chmod 600 ~/.kube/config

# SSH key for the workers
cp <private-key> ~/.ssh/k8s-aware && chmod 600 ~/.ssh/k8s-aware
for ip in <worker1-ip> <worker2-ip> <worker3-ip>; do
  ssh -i ~/.ssh/k8s-aware -o StrictHostKeyChecking=accept-new ubuntu@$ip 'hostname; sudo -n true && echo sudo-ok'
done

# Toolchain: rust-toolchain.toml pins Rust 1.97.1
command -v rustup || curl -sSf https://sh.rustup.rs | sh -s -- -y
. ~/.cargo/env
python3 --version; tmux -V; curl --version | head -1
```

## 3. Preflight

```bash
kubectl get nodes
kubectl -n failure-aware-writer-test get pods                                  # expect none
ssh -i ~/.ssh/k8s-aware ubuntu@<worker3-ip> 'sudo /usr/local/sbin/fa-writer-fence-w2 status'   # expect ABSENT
ssh -i ~/.ssh/k8s-aware ubuntu@<worker1-ip> 'pgrep -a mariadbd'                 # expect nothing
```

Optionally, scale down other workloads on Worker1 so that repeated
partitions do not keep evicting them. Record their state first so it can
be restored.

## 4. Run

```bash
tmux new -s campaign
export SSH_KEY=~/.ssh/k8s-aware
scripts/ladder/campaign.sh all 2>&1 | tee -a ~/ladder.log
scripts/live-writer/campaign.sh run 2>&1 | tee -a ~/live-writer.log
```

Detach with `Ctrl-b`, then `d`. Check progress with:

```bash
scripts/ladder/campaign.sh status
scripts/live-writer/campaign.sh status
```

- **Ladder stage** (75 runs): about 11 hours.
- **Probe grid and overhead:** about 2.5 hours.
- **Live-writer test** (20 runs): about 3.5 hours.

How the runners behave:

- Each runner creates its campaign directory and random seed on first
  use and resumes from where it stopped.
- Completed runs are never repeated or overwritten.
- An interrupted ladder run clears its fault and keeps its directory,
  marked `ABORTED`.
- The live-writer runner stops at the first abnormal state instead of
  removing a fence, because removing it could let a stale writer
  resume. Inspect `ABORTED` and `preflight.log` before restarting.

Set `SEED=<number>` before the first invocation to reuse a seed.

## 5. Analyse

```bash
python3 analysis/analyze-ladder.py experiments/evaluation/ladder/CURRENT --output analysis/results/ladder
python3 analysis/analyze-live-writer.py experiments/evaluation/live-writer/CURRENT --output analysis/results/live-writer
```

The scripts print the H1–H5 verdicts. They also write the per-run tables,
per-cell tables and inventory tables, including attempted, aborted and
completed runs.

## 6. Evidence layout

```text
experiments/evaluation/ladder/<campaign>/
    seed.txt, campaign.env, ladder-plan.csv, preflight.log
    runs/<run-id>/            one directory per run (and per earlier attempt)
    probe-grid/               plan.csv, trials.csv, attempts.csv, self-test.txt
    overhead/                 controller-overhead-windows.csv, controller-binary.sha256
experiments/evaluation/live-writer/<campaign>/
    seed.txt, campaign.env, plan.csv
    runs/<run-id>/            committed-rows.csv, writer logs, fence logs, clock offsets
```
