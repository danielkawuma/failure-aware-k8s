# Failure-Aware Container Orchestration under Node and Network Partitions

Source code, experiment scripts, run evidence and analysis for the paper
*Failure-Aware Container Orchestration under Node and Network Partitions in
Resource-Constrained Healthcare Cloud Environments* (Kawuma Daniel, Fred Wabendo).

Kubernetes treats a worker it can no longer hear from as failed: after the
node-monitor grace period the node becomes `Ready=Unknown`, and once a Pod's
toleration expires the Pod is evicted and replaced, even when it is still
serving its clients. For a database, a replacement started while the original
is still running can also produce two writers.

This repository contains a Rust controller for K3s that acts **after** native
suspicion. It probes the suspected workload over an independent path and then

- **PRESERVE**s a workload that still answers, so it is not replaced, or
- **RECOVER**s a workload that does not, onto a verified node, and for a
  duplication-sensitive workload fences its storage first and keeps the fence
  until the previous writer is retired.

Kubernetes keeps scheduling and lifecycle; the controller only decides.

```
Kubernetes suspicion (Ready=Unknown)
  -> post-suspicion verification (bounded HTTP probes, independent path)
  -> decision: workload, resource and recovery-safety awareness
  -> PRESERVE | RECOVER (storage fence first for duplication-sensitive workloads)
  -> native Kubernetes scheduling and Pod lifecycle
```

## Results in brief

The cluster runs K3s v1.36.4 on five OpenStack virtual machines spread over
three availability zones. The paper reports every figure with its interval.

| Question | Result |
|---|---|
| Is a reachable workload kept through a 600-s partition? | Native K3s replaced it in 30 of 30 runs; the controller with non-expiring tolerations kept it in 32 of 32 valid runs. |
| Against tuned and replicated baselines (ladder) | Only the controller arm both kept the reachable workload and recovered an unreachable one within 15 s of a 10-s toleration (63.9 s against 62.2 s). |
| After a real worker shutdown | Service restored in 4 of 5 runs; five-run median outage 62 s against 350 s natively. |
| Database writer during a partition | With the fence the original committed nothing after it in 20 of 20 runs; without it, about 1,025 rows per run after the replacement was released. |
| Probe errors | No false RECOVER in 200 healthy or 10%-loss trials and no false PRESERVE in 100 unreachable trials. |
| Overhead | About 1 millicore of CPU and 20 MiB of memory. |

## Repository layout

```
controller/            Rust controller (suspicion, verification, decision, enforcement, fencing)
harness/               Rust observation harness (HTTP, nodes, Leases, Pods, taints, events)
workloads/             Manifests: Nginx ladder arms, OpenMRS 3.7.1 + MariaDB, stateful fencing
scripts/
  cluster/             provision.sh: builds the K3s cluster and writes a kubeconfig
  ladder/              baseline ladder, probe grid and overhead campaigns
  live-writer/         live-writer fencing campaign
  openmrs/             OpenMRS scenarios, fencing, diagnostics, clinical load campaign
  fault.sh             fault injection (iptables partitions, tc/NetEm degradation)
tools/openmrs-load/    clinical load generator (standard library only)
analysis/              analysis scripts; analysis/results/ holds their outputs
experiments/evaluation/ raw per-run evidence of every campaign
docs/
  review/              search log, screening and coding records, review workbook, AI-use log
  supplementary/       supplementary material of the paper
  figures/             figure sources (draw.io) and images
REPRODUCIBILITY.md     step-by-step guide from provisioning to every reported table
```

## Quick start

### 1. Build the cluster

Five Ubuntu 24.04 VMs with SSH access and passwordless sudo: one control-plane
node and four workers (Worker1 is the fault target, Worker2 the recovery target).

```bash
cp scripts/cluster/cluster.env.example scripts/cluster/cluster.env   # set your addresses
bash scripts/cluster/provision.sh
export KUBECONFIG=$PWD/kubeconfig/cluster.kubeconfig
```

`provision.sh` installs the pinned K3s version, joins the workers, labels the
nodes, creates the `failure-aware` namespace, sets up the NFS export and writes
the kubeconfig. `cluster.env` and `kubeconfig/` are not committed.

Set the same addresses in `scripts/experiment-config.sh` before running
experiments.

### 2. Build the controller and harness

```bash
make build        # Rust toolchain pinned by rust-toolchain.toml and Cargo.lock
make validate     # SSH, cluster and binary checks
```

### 3. Regenerate every reported result from the recorded evidence

```bash
make reproduce
```

This runs no experiment. It checks the evidence, regenerates each table and
statistic of the paper, recomputes the literature-review counts
(`analysis/review-counts.py`) and prints PASS or FAIL per stage.

### 4. Run new experiments (prepared testbed only)

```bash
make reproduce run CONFIRM_EXPERIMENTS=YES
```

Individual campaigns:

| Campaign | Command |
|---|---|
| Baseline ladder (V0, T10, NX, R2, FA1) | `scripts/ladder/campaign.sh ladder` |
| Live-writer fencing | `LW_ARMS=fenced RUNS_PER_ARM=10 scripts/live-writer/campaign.sh run` |
| OpenMRS Scenario B under clinical load | `bash scripts/openmrs/load/run-openmrs-load-campaign.sh` (needs `OPENMRS_USER`, `OPENMRS_PASS`, `OPENMRS_BASE_URL`) |

Every campaign logs its seed and run order before the first run, and every
attempt keeps its directory under `experiments/evaluation/`.

## Pre-registration

- Experimental design (Scenarios A to E) and first-phase hypotheses: commit `b2560cf`.
- Hypotheses H1 to H5 with falsifying numbers: commit `4ce8078`, before the
  second-phase campaigns.
- Extension addendum: commit `ddfc677`.

## Data

The OpenMRS database holds synthetic patients only, created through the
OpenMRS REST API by `scripts/openmrs/seed-patients.py` and
`seed-clinical-data.py`. No real patient data was collected. Testbed addresses
and credentials are removed from the published records; the OpenMRS password is
read from an environment variable and is never stored.

## AI use

The use of ChatGPT and Claude is recorded, with dates, purposes, files affected
and verification, in the `AI_Use_Log` sheet of `docs/review/review-workbook.xlsx`
and summarised in the paper's Acknowledgment.

## Citation

Release `v1.1.1-research`, archived on Zenodo (DOI to be added). Release
`v1.0.0-research` is kept unchanged.

## License

MIT License; see `LICENSE`.
