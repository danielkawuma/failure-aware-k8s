# Experimental Testbed

## Infrastructure

The initial experimental environment is hosted on Proxmox and consists
of three virtual machines running K3s.

| Node | Role | vCPU | RAM | Disk |
|---|---|---:|---:|---:|
| k3s-server | Control plane | 4 | 4 GB | 100 GB |
| worker-a | Primary experimental worker | 4 | 4 GB | 100 GB |
| worker-b | Recovery target | 4 | 4 GB | 100 GB |

The Rust experimental harness and external workload generator run from
a separate client machine outside the K3s cluster.

## Node Roles

### k3s-server

Runs the K3s control plane.

Primary responsibilities:

- Kubernetes API Server
- Controller Manager
- Scheduler
- etcd/K3s datastore
- Node and Lease observation

### worker-a

Primary fault-injection target.

This worker will host workloads used for:

- node-failure experiments
- control-plane partition experiments
- network-degradation experiments
- workload reachability verification

### worker-b

Recovery target.

This worker provides available capacity when workloads require
recovery after Worker A becomes unavailable.

## External Client

The external client machine runs:

- Rust experimental harness
- workload generation
- experiment coordination
- result collection
- analysis tooling

## Initial Resource Profile

The initial development profile is:

- Worker CPU: 2 vCPU
- Worker RAM: 2 GB

Additional constrained profiles will later be evaluated, including:

- 1 vCPU / 1 GB RAM
- 2 vCPU / 2 GB RAM
- 4 vCPU / 4 GB RAM

Formal resource profiles will be frozen before headline experiments.
